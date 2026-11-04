//+------------------------------------------------------------------+
//|                                      XAUUSD_M1_ScalperProMax.mq5 |
//|          XAUUSD M1 multi-strategy scalper with a weekly target   |
//|             https://github.com/vinada08/xauusd-pro-calculator-   |
//+------------------------------------------------------------------+
//|  Strategies (all ATR-adaptive, evaluated on closed M1 bars):      |
//|   1. Trend Pullback   - M15 EMA trend + M5 ADX + M1 EMA21 pullback |
//|   2. Opening Range BO - London / New York opening-range breakout  |
//|   3. VWAP Reversion   - fade over-extension back to daily VWAP    |
//|                                                                   |
//|  Money management:                                                |
//|   - Weekly profit target (default 250) -> close & stop for week   |
//|   - Daily pace goal = remaining weekly target / days left         |
//|   - Risk-% sizing, house-money + pace boost (never martingale)    |
//|   - Hard per-trade risk cap, daily/weekly loss limits, equity DD  |
//|                                                                   |
//|  DISCLAIMER: no EA can guarantee a profit target. Back-test on    |
//|  real ticks and run on demo before risking real money.            |
//+------------------------------------------------------------------+
#property copyright   "vinada08 - xauusd-pro-calculator"
#property link        "https://github.com/vinada08/xauusd-pro-calculator-"
#property version     "1.00"
#property description "XAUUSD M1 Scalper Pro Max: trend pullback, London/NY opening-range breakout and"
#property description "VWAP mean reversion with a weekly profit target, pace-aware position sizing,"
#property description "daily/weekly loss limits, spread and news filters. No EA can guarantee profit."

#include <Trade/Trade.mqh>

#define EA_NAME     "XAUUSD M1 Scalper Pro Max"
#define EA_VER      "1.00"
#define OBJ_PREFIX  "PMX_"
#define LOCK_TARGET 1
#define LOCK_LOSS   2
#define LOCK_DD     3

//+------------------------------------------------------------------+
//| Enums                                                             |
//+------------------------------------------------------------------+
enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0, // Fixed lot
   LOT_RISK_PERCENT = 1, // Risk % of equity per trade
   LOT_RISK_MONEY   = 2  // Fixed money risk per trade
  };

enum ENUM_GMT_MODE
  {
   GMT_AUTO         = 0, // Auto (live) / NY-close DST in tester
   GMT_MANUAL       = 1, // Manual offset (hours)
   GMT_NY_CLOSE_DST = 2  // Broker GMT+2 winter / GMT+3 summer
  };

enum ENUM_DIR_MODE
  {
   DIR_BOTH  = 0, // Long and short
   DIR_LONG  = 1, // Long only
   DIR_SHORT = 2  // Short only
  };

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "=== General ==="
input long            InpMagic               = 20262027;       // Magic number
input string          InpComment             = "PMX";          // Order comment prefix
input ENUM_DIR_MODE   InpDirection           = DIR_BOTH;       // Allowed trade direction
input int             InpSlippagePoints      = 30;             // Max slippage (points)
input double          InpCommissionPerLot    = 7.0;            // Round-turn commission per lot (sizing only)

input group "=== Weekly / Daily Targets ==="
input double          InpWeeklyTarget        = 250.0;          // Weekly profit target (account currency)
input bool            InpStopOnWeeklyTarget  = true;           // Stop trading for the week when target is hit
input bool            InpCloseOnWeeklyTarget = true;           // Close open trades the moment target is hit
input bool            InpStopOnDailyTarget   = true;           // Stop for the day when the daily pace goal is hit
input bool            InpCloseOnDailyTarget  = true;           // Close open trades when the daily goal is hit
input double          InpDailyTargetFactor   = 1.0;            // Daily goal = remaining weekly / days left x factor
input double          InpDailyMaxLoss        = 100.0;          // Daily max loss, closed+floating (0 = off)
input double          InpWeeklyMaxLoss       = 250.0;          // Weekly max loss, closed+floating (0 = off)
input double          InpMaxEquityDDPct      = 8.0;            // Emergency close at floating DD % of balance (0 = off)
input bool            InpResetLocksOnStart   = false;          // Clear daily/weekly locks when EA starts

input group "=== Position Sizing (lot size grows with equity & profit) ==="
input ENUM_LOT_MODE   InpLotMode             = LOT_RISK_PERCENT; // Lot sizing mode
input double          InpFixedLot            = 0.02;           // Fixed lot (LOT_FIXED)
input double          InpRiskPercent         = 0.75;           // Risk % of equity per trade (LOT_RISK_PERCENT)
input double          InpRiskMoney           = 25.0;           // Money risked per trade (LOT_RISK_MONEY)
input double          InpMaxLot              = 1.00;           // Maximum lot per trade
input double          InpMaxRiskPctCap       = 2.0;            // HARD CAP: max risk % of equity per trade incl. boosts
input bool            InpUseHouseMoney       = true;           // Add a slice of this week's profit to risk
input double          InpHouseMoneyPct       = 10.0;           // % of weekly closed profit added to per-trade risk
input bool            InpUsePaceBoost        = true;           // Boost size when week is green but behind pace
input double          InpPaceBoostMax        = 1.5;            // Max pace boost multiplier
input bool            InpUseLossReduce       = true;           // Cut size after consecutive losses
input int             InpLossReduceAfter     = 2;              // ...after N consecutive losses
input double          InpLossReduceFactor    = 0.5;            // ...risk multiplier while in a losing streak
input bool            InpRightSizeNearGoal   = true;           // Shrink lot when TP alone would beat remaining target

input group "=== Strategy 1: Trend Pullback ==="
input bool            InpUseTrendPullback    = true;           // Enable trend pullback
input ENUM_TIMEFRAMES InpTrendTF             = PERIOD_M15;     // Higher-timeframe trend
input int             InpTrendEmaFast        = 50;             // HTF fast EMA
input int             InpTrendEmaSlow        = 200;            // HTF slow EMA
input int             InpEmaFast             = 9;              // M1 trigger EMA
input int             InpEmaMid              = 21;             // M1 pullback EMA
input int             InpEmaSlow             = 50;             // M1 structure EMA
input int             InpPullbackLookback    = 6;              // Bars to search for the pullback (2-20)
input double          InpRsiPullbackLevel    = 40.0;           // RSI dip level (buy) / 100-x (sell)
input double          InpTrendRR             = 1.5;            // Take profit (R multiple)

input group "=== Strategy 2: Session Opening-Range Breakout ==="
input bool            InpUseBreakout         = true;           // Enable opening-range breakout
input string          InpLondonORStart       = "08:00";        // London OR start (London local time)
input string          InpNYORStart           = "09:30";        // New York OR start (New York local time)
input int             InpORMinutes           = 15;             // Opening range length (minutes)
input int             InpBreakoutWindow      = 90;             // Minutes after the OR where breakouts are valid
input double          InpORMinATR            = 1.5;            // Min OR height (x M1 ATR)
input double          InpORMaxATR            = 10.0;           // Max OR height (x M1 ATR)
input double          InpBreakBufferATR      = 0.15;           // Close beyond range by x ATR
input bool            InpBreakoutTrendFilter = true;           // Never break out against the HTF trend
input double          InpBreakoutRR          = 1.8;            // Take profit (R multiple)

input group "=== Strategy 3: VWAP Mean Reversion ==="
input bool            InpUseVwap             = true;           // Enable VWAP reversion
input double          InpVwapDevATR          = 2.0;            // Min stretch from VWAP (x ATR)
input double          InpRsiOversold         = 25.0;           // RSI oversold (overbought = 100-x)
input double          InpVwapMinRR           = 0.8;            // Min reward:risk to VWAP
input double          InpVwapMaxRR           = 2.5;            // Cap TP at this R when VWAP is far
input int             InpVwapMinBars         = 30;             // Min M1 bars since day start
input bool            InpVwapCounterTrend    = false;          // Allow fades against the HTF trend

input group "=== Indicators / Regime ==="
input int             InpRsiPeriod           = 7;              // RSI period (M1)
input int             InpAtrPeriod           = 14;             // ATR period (M1)
input ENUM_TIMEFRAMES InpRegimeTF            = PERIOD_M5;      // Regime (ADX) timeframe
input int             InpAdxPeriod           = 14;             // ADX period
input double          InpAdxTrendMin         = 20.0;           // ADX >= this -> trend strategies allowed
input double          InpAdxRangeMax         = 22.0;           // ADX <= this -> VWAP reversion allowed

input group "=== Stops & Trade Management ==="
input double          InpMinSL_ATR           = 0.8;            // Min stop distance (x ATR)
input double          InpMaxSL_ATR           = 2.5;            // Max stop distance (x ATR)
input bool            InpUseBreakEven        = true;           // Move stop to break-even
input double          InpBE_TriggerR         = 0.8;            // ...when profit reaches x R
input double          InpBE_LockR            = 0.1;            // ...locking x R
input bool            InpUsePartial          = true;           // Partial take profit
input double          InpPartialR            = 1.0;            // ...at x R
input double          InpPartialPct          = 50.0;           // ...closing this % of volume
input bool            InpUseTrailing         = true;           // ATR trailing stop
input double          InpTrailStartR         = 1.2;            // ...start at x R
input double          InpTrailATR            = 1.0;            // ...trail distance (x ATR)
input int             InpMaxHoldMinutes      = 45;             // Time stop in minutes (0 = off)

input group "=== Filters ==="
input double          InpMaxSpreadUSD        = 0.40;           // Max spread in price ($ per oz)
input double          InpMaxSpreadATRFrac    = 0.30;           // Max spread as fraction of M1 ATR
input double          InpMinATR_USD          = 0.50;           // Min M1 ATR in price (dead market filter)
input double          InpMaxATR_USD          = 10.0;           // Max M1 ATR in price (spike filter)
input int             InpMaxOpenPositions    = 1;              // Max simultaneous positions
input int             InpMaxTradesPerDay     = 12;             // Max new trades per day
input int             InpMaxConsecLossesDay  = 4;              // Stop for the day after N losses in a row
input int             InpCooldownMinutes     = 5;              // Pause after a losing trade (minutes)
input int             InpMinMinutesBetween   = 3;              // Min minutes between entries

input group "=== Sessions & Time (DST handled automatically) ==="
input ENUM_GMT_MODE   InpGMTMode             = GMT_AUTO;       // Broker GMT offset mode
input int             InpManualGMTOffset     = 2;              // Manual broker GMT offset (hours)
input bool            InpTradeLondon         = true;           // Trade London session
input string          InpLondonSession       = "08:00-11:30";  // London session (London local time)
input bool            InpTradeNewYork        = true;           // Trade New York session
input string          InpNYSession           = "08:00-12:00";  // New York session (New York local time)
input bool            InpTradeAsia           = false;          // Trade Asian session
input string          InpAsiaSessionGMT      = "00:30-04:00";  // Asian session (GMT)
input bool            InpFridayClose         = true;           // Flat before the weekend
input string          InpFridayCloseNY       = "12:30";        // Friday close time (New York local time)

input group "=== News Filter (live/demo only - calendar is not available in tester) ==="
input bool            InpUseNews             = true;           // Block entries around news
input string          InpNewsCurrencies      = "USD";          // Currencies (comma separated)
input int             InpNewsMinsBefore      = 15;             // Minutes before event
input int             InpNewsMinsAfter       = 15;             // Minutes after event
input bool            InpNewsIncludeMedium   = false;          // Also block medium-impact events

input group "=== Display & Alerts ==="
input bool            InpShowPanel           = true;           // Show dashboard
input bool            InpPushNotify          = false;          // Push notification on target / limits
input bool            InpVerbose             = true;           // Detailed journal logging

//+------------------------------------------------------------------+
//| Types & globals                                                   |
//+------------------------------------------------------------------+
struct Signal
  {
   int               dir;     // +1 buy, -1 sell
   double            sl;      // structural stop price
   double            tp;      // fixed TP price (0 = use rr)
   double            rr;      // reward multiple when tp == 0
   int               orIdx;   // opening-range index (-1 = none)
   string            name;
  };

struct ORState
  {
   datetime          start;   // OR start (server time)
   double            hi;
   double            lo;
   bool              ready;
   bool              tradedLong;
   bool              tradedShort;
  };

CTrade   trade;

int      hEmaFast   = INVALID_HANDLE;
int      hEmaMid    = INVALID_HANDLE;
int      hEmaSlow   = INVALID_HANDLE;
int      hRsi       = INVALID_HANDLE;
int      hAtr       = INVALID_HANDLE;
int      hTrendFast = INVALID_HANDLE;
int      hTrendSlow = INVALID_HANDLE;
int      hAdx       = INVALID_HANDLE;

// time context
datetime g_server = 0, g_gmt = 0, g_dayStart = 0, g_weekStart = 0;
int      g_gmtOffsetSec = 0;
bool     g_usDst = false, g_ukDst = false;

// parsed session times (minutes of day)
int      g_lonFrom = 0, g_lonTo = 0, g_nyFrom = 0, g_nyTo = 0, g_asFrom = 0, g_asTo = 0;
int      g_lonOR = 0, g_nyOR = 0, g_friClose = 0;

// statistics
double   g_weekClosed = 0, g_todayClosed = 0, g_floating = 0;
int      g_openCount = 0, g_tradesToday = 0, g_weekWins = 0, g_weekLosses = 0;
int      g_consecLossWeek = 0, g_consecLossToday = 0;
bool     g_hasBuy = false, g_hasSell = false, g_lastExitLoss = false;
datetime g_lastExitTime = 0, g_lastEntryTime = 0;
bool     g_statsDirty = true;

// market cache
double   g_atr = 0, g_adx = -1, g_vwap = 0;
int      g_bias = 0, g_vwapBars = 0;
datetime g_lastBarTime = 0;
ORState  g_or[2];

// UI / status
string   g_session = "", g_lastSignal = "-", g_filterNote = "";
double   g_lastRisk = 0, g_lastMult = 1.0;

// weekly target statistics (printed in tester)
datetime g_trackWeek = 0;
int      g_weeksTotal = 0, g_weeksHit = 0, g_weeksRed = 0;
bool     g_weekHitFlag = false;
double   g_bestWeek = 0, g_worstWeek = 0;

// news cache
datetime g_newsTimes[];
string   g_newsNames[];
datetime g_newsLoaded = 0;

datetime g_lastGVClean = 0;

//+------------------------------------------------------------------+
//| Small helpers                                                     |
//+------------------------------------------------------------------+
void Log(const string msg)
  {
   if(InpVerbose)
      Print(EA_NAME, ": ", msg);
  }

bool IsTester()   { return(MQLInfoInteger(MQL_TESTER) != 0); }
bool IsHedging()  { return(AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING); }

bool DirAllowed(const int d)
  {
   if(InpDirection == DIR_BOTH) return(true);
   if(InpDirection == DIR_LONG) return(d > 0);
   return(d < 0);
  }

string Money(const double v)
  {
   return((v >= 0 ? "+" : "") + DoubleToString(v, 2));
  }

string ProgressBar(double frac, const int width)
  {
   frac = MathMax(0.0, MathMin(1.0, frac));
   int filled = (int)MathRound(frac * width);
   string s = "[";
   for(int i = 0; i < width; i++)
      s += (i < filled) ? "#" : ".";
   return(s + "]");
  }

int VolumeDigits(double step)
  {
   int d = 0;
   while(step < 1.0 - 1e-9 && d < 8)
     {
      step *= 10.0;
      d++;
     }
   return(d);
  }

double NormalizePrice(double p)
  {
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts > 0)
      p = MathRound(p / ts) * ts;
   return(NormalizeDouble(p, _Digits));
  }

string GVKey(const string k)              { return(OBJ_PREFIX + IntegerToString(InpMagic) + "_" + _Symbol + "_" + k); }
string GVPos(const string k, const ulong t) { return(OBJ_PREFIX + k + "_" + IntegerToString((long)t)); }

//+------------------------------------------------------------------+
//| Time parsing                                                      |
//+------------------------------------------------------------------+
int ParseHHMM(string s)
  {
   StringTrimLeft(s);
   StringTrimRight(s);
   string p[];
   if(StringSplit(s, ':', p) != 2)
      return(-1);
   int h = (int)StringToInteger(p[0]);
   int m = (int)StringToInteger(p[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59)
      return(-1);
   return(h * 60 + m);
  }

bool ParseRange(const string s, int &from, int &to)
  {
   string p[];
   if(StringSplit(s, '-', p) != 2)
      return(false);
   from = ParseHHMM(p[0]);
   to   = ParseHHMM(p[1]);
   return(from >= 0 && to >= 0);
  }

bool InRange(const int minute, const int from, const int to)
  {
   if(from <= to)
      return(minute >= from && minute < to);
   return(minute >= from || minute < to);        // wraps midnight
  }

int MinuteOfDay(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return(s.hour * 60 + s.min);
  }

int DowOf(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return(s.day_of_week);
  }

datetime MakeDate(const int y, const int mon, const int d)
  {
   MqlDateTime t;
   ZeroMemory(t);
   t.year = y;
   t.mon  = mon;
   t.day  = d;
   return(StructToTime(t));
  }

datetime NthSunday(const int y, const int mon, const int n)
  {
   datetime first = MakeDate(y, mon, 1);
   int off = (7 - DowOf(first)) % 7;
   return(first + (datetime)((off + (n - 1) * 7) * 86400));
  }

datetime LastSunday(const int y, const int mon)
  {
   int ny = (mon == 12) ? y + 1 : y;
   int nm = (mon == 12) ? 1 : mon + 1;
   datetime last = MakeDate(ny, nm, 1) - 86400;
   return(last - (datetime)(DowOf(last) * 86400));
  }

// US DST: 2nd Sunday of March 02:00 local -> 1st Sunday of November 02:00 local
bool IsUSDST(const datetime gmt)
  {
   MqlDateTime s;
   TimeToStruct(gmt, s);
   datetime st = NthSunday(s.year, 3, 2) + 7 * 3600;
   datetime en = NthSunday(s.year, 11, 1) + 6 * 3600;
   return(gmt >= st && gmt < en);
  }

// UK/EU DST: last Sunday of March 01:00 GMT -> last Sunday of October 01:00 GMT
bool IsUKDST(const datetime gmt)
  {
   MqlDateTime s;
   TimeToStruct(gmt, s);
   datetime st = LastSunday(s.year, 3) + 3600;
   datetime en = LastSunday(s.year, 10) + 3600;
   return(gmt >= st && gmt < en);
  }

int ComputeGMTOffsetSec(const datetime server)
  {
   if(InpGMTMode == GMT_MANUAL)
      return(InpManualGMTOffset * 3600);
   if(InpGMTMode == GMT_AUTO && !IsTester())
     {
      long diff = (long)TimeTradeServer() - (long)TimeGMT();
      return((int)(MathRound((double)diff / 900.0) * 900.0));   // round to 15 min
     }
   // NY-close brokers (most XAUUSD brokers) - also the tester fallback for AUTO
   return(IsUSDST(server - 2 * 3600) ? 3 * 3600 : 2 * 3600);
  }

void RefreshTime()
  {
   g_server       = TimeCurrent();
   g_gmtOffsetSec = ComputeGMTOffsetSec(g_server);
   g_gmt          = g_server - g_gmtOffsetSec;
   g_usDst        = IsUSDST(g_gmt);
   g_ukDst        = IsUKDST(g_gmt);
   MqlDateTime s;
   TimeToStruct(g_server, s);
   g_dayStart  = g_server - (datetime)(s.hour * 3600 + s.min * 60 + s.sec);
   g_weekStart = g_dayStart - (datetime)(s.day_of_week * 86400);      // Sunday 00:00 server
  }

datetime LondonLocal() { return(g_gmt + (g_ukDst ? 3600 : 0)); }
datetime NYLocal()     { return(g_gmt - (g_usDst ? 4 * 3600 : 5 * 3600)); }

int TradingDaysLeft()
  {
   int d = DowOf(g_server);
   if(d == 0) return(5);
   if(d == 6) return(0);
   return(6 - d);                 // Monday = 5 ... Friday = 1 (today included)
  }

string ActiveSession()
  {
   if(InpTradeLondon  && InRange(MinuteOfDay(LondonLocal()), g_lonFrom, g_lonTo)) return("London");
   if(InpTradeNewYork && InRange(MinuteOfDay(NYLocal()),     g_nyFrom,  g_nyTo))  return("New York");
   if(InpTradeAsia    && InRange(MinuteOfDay(g_gmt),         g_asFrom,  g_asTo))  return("Asia");
   return("");
  }

bool FridayCutoff()
  {
   if(!InpFridayClose)
      return(false);
   MqlDateTime s;
   TimeToStruct(NYLocal(), s);
   if(s.day_of_week == 6)
      return(true);
   return(s.day_of_week == 5 && s.hour * 60 + s.min >= g_friClose);
  }

// Opening-range start for today in server time. idx 0 = London, 1 = New York
datetime ORStartServer(const int idx)
  {
   datetime local   = (idx == 0) ? LondonLocal() : NYLocal();
   int      offset  = (idx == 0) ? (g_ukDst ? 3600 : 0) : (g_usDst ? -4 * 3600 : -5 * 3600);
   MqlDateTime s;
   TimeToStruct(local, s);
   datetime midnight = local - (datetime)(s.hour * 3600 + s.min * 60 + s.sec);
   datetime start    = midnight + (datetime)(((idx == 0) ? g_lonOR : g_nyOR) * 60);
   return(start - offset + g_gmtOffsetSec);
  }

//+------------------------------------------------------------------+
//| Locks (persist across restarts via terminal global variables)    |
//+------------------------------------------------------------------+
void LockWeek(const int why)
  {
   GlobalVariableSet(GVKey("WLOCK"), (double)g_weekStart);
   GlobalVariableSet(GVKey("WWHY"), why);
  }

void LockDay(const int why)
  {
   GlobalVariableSet(GVKey("DLOCK"), (double)g_dayStart);
   GlobalVariableSet(GVKey("DWHY"), why);
  }

bool IsWeekLocked(int &why)
  {
   string k = GVKey("WLOCK");
   if(!GlobalVariableCheck(k) || (datetime)(long)GlobalVariableGet(k) != g_weekStart)
      return(false);
   why = (int)GlobalVariableGet(GVKey("WWHY"));
   return(true);
  }

bool IsDayLocked(int &why)
  {
   string k = GVKey("DLOCK");
   if(!GlobalVariableCheck(k) || (datetime)(long)GlobalVariableGet(k) != g_dayStart)
      return(false);
   why = (int)GlobalVariableGet(GVKey("DWHY"));
   return(true);
  }

void ClearLocks()
  {
   GlobalVariableDel(GVKey("WLOCK"));
   GlobalVariableDel(GVKey("WWHY"));
   GlobalVariableDel(GVKey("DLOCK"));
   GlobalVariableDel(GVKey("DWHY"));
  }

void Notify(const string msg)
  {
   Print(EA_NAME, ": ", msg);
   if(InpPushNotify && !IsTester())
      SendNotification(EA_NAME + " " + _Symbol + ": " + msg);
  }

//+------------------------------------------------------------------+
//| Deal / statistics                                                 |
//+------------------------------------------------------------------+
bool IsOurDeal(const ulong d)
  {
   if(d == 0) return(false);
   if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) return(false);
   if(HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic) return(false);
   long t = HistoryDealGetInteger(d, DEAL_TYPE);
   return(t == DEAL_TYPE_BUY || t == DEAL_TYPE_SELL);
  }

double DealNet(const ulong d)
  {
   return(HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) +
          HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE));
  }

double ClosedPL(const datetime from, const datetime to)
  {
   double sum = 0;
   if(!HistorySelect(from, to))
      return(0);
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(!IsOurDeal(d)) continue;
      datetime t = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
      if(t < from || t >= to) continue;
      sum += DealNet(d);
     }
   return(sum);
  }

void RefreshStats()
  {
   g_statsDirty      = false;
   g_weekClosed      = 0;
   g_todayClosed     = 0;
   g_tradesToday     = 0;
   g_weekWins        = 0;
   g_weekLosses      = 0;
   g_consecLossWeek  = 0;
   g_consecLossToday = 0;
   g_lastExitTime    = 0;
   g_lastExitLoss    = false;
   g_lastEntryTime   = 0;

   if(!HistorySelect(g_weekStart, TimeCurrent() + 86400))
     {
      g_statsDirty = true;
      return;
     }

   ulong    ids[];
   double   nets[];
   datetime lasts[];
   bool     exits[];
   int      cnt = 0;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(!IsOurDeal(d)) continue;
      datetime t   = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
      long entry   = HistoryDealGetInteger(d, DEAL_ENTRY);
      double net   = DealNet(d);
      ulong pid    = (ulong)HistoryDealGetInteger(d, DEAL_POSITION_ID);

      g_weekClosed += net;
      if(t >= g_dayStart) g_todayClosed += net;

      if(entry == DEAL_ENTRY_IN)
        {
         if(t >= g_dayStart) g_tradesToday++;
         if(t > g_lastEntryTime) g_lastEntryTime = t;
        }

      int k = -1;
      for(int j = 0; j < cnt; j++)
         if(ids[j] == pid) { k = j; break; }
      if(k < 0)
        {
         cnt++;
         ArrayResize(ids, cnt);
         ArrayResize(nets, cnt);
         ArrayResize(lasts, cnt);
         ArrayResize(exits, cnt);
         k = cnt - 1;
         ids[k] = pid; nets[k] = 0; lasts[k] = 0; exits[k] = false;
        }
      nets[k] += net;
      if(entry != DEAL_ENTRY_IN)
        {
         exits[k] = true;
         if(t > lasts[k]) lasts[k] = t;
        }
     }

   // insertion sort by last exit time
   for(int a = 1; a < cnt; a++)
     {
      ulong id = ids[a]; double n = nets[a]; datetime l = lasts[a]; bool e = exits[a];
      int b = a - 1;
      while(b >= 0 && lasts[b] > l)
        {
         ids[b + 1] = ids[b]; nets[b + 1] = nets[b]; lasts[b + 1] = lasts[b]; exits[b + 1] = exits[b];
         b--;
        }
      ids[b + 1] = id; nets[b + 1] = n; lasts[b + 1] = l; exits[b + 1] = e;
     }

   for(int j = 0; j < cnt; j++)
     {
      if(!exits[j]) continue;
      if(PositionSelectByTicket(ids[j])) continue;       // still open (partial close only)
      bool loss = (nets[j] < 0);
      if(loss) { g_weekLosses++; g_consecLossWeek++; }
      else     { g_weekWins++;   g_consecLossWeek = 0; }
      if(lasts[j] >= g_dayStart)
        {
         if(loss) g_consecLossToday++;
         else     g_consecLossToday = 0;
        }
      g_lastExitTime = lasts[j];
      g_lastExitLoss = loss;
     }
  }

void UpdateFloating()
  {
   double fl = 0;
   int    cnt = 0;
   bool   hb = false, hs = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      fl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      cnt++;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) hb = true;
      else hs = true;
     }
   if(cnt != g_openCount)
      g_statsDirty = true;          // a position opened/closed -> history changed
   g_floating  = fl;
   g_openCount = cnt;
   g_hasBuy    = hb;
   g_hasSell   = hs;
  }

double DailyTarget()
  {
   if(InpWeeklyTarget <= 0)
      return(0);
   double remaining = InpWeeklyTarget - (g_weekClosed - g_todayClosed);
   if(remaining <= 0)
      return(0);
   int days = TradingDaysLeft();
   if(days <= 0)
      return(remaining);
   return(remaining / days * InpDailyTargetFactor);
  }

//+------------------------------------------------------------------+
//| Weekly-target tracking (tester report)                            |
//+------------------------------------------------------------------+
void RecordWeek(const datetime ws, const double pl)
  {
   g_weeksTotal++;
   bool hit = g_weekHitFlag || (InpWeeklyTarget > 0 && pl >= InpWeeklyTarget);
   if(hit) g_weeksHit++;
   if(pl < 0) g_weeksRed++;
   if(g_weeksTotal == 1 || pl > g_bestWeek)  g_bestWeek  = pl;
   if(g_weeksTotal == 1 || pl < g_worstWeek) g_worstWeek = pl;
   PrintFormat("WEEK %s | P/L %s | %s | target hit %d of %d weeks",
               TimeToString(ws, TIME_DATE), Money(pl), hit ? "TARGET HIT" : "target missed",
               g_weeksHit, g_weeksTotal);
  }

void TrackWeekRollover()
  {
   if(g_trackWeek == 0)
     {
      g_trackWeek = g_weekStart;
      return;
     }
   if(g_weekStart == g_trackWeek)
      return;
   RecordWeek(g_trackWeek, ClosedPL(g_trackWeek, g_weekStart));
   g_trackWeek   = g_weekStart;
   g_weekHitFlag = false;
   g_statsDirty  = true;
  }

//+------------------------------------------------------------------+
//| Market data                                                       |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t = iTime(_Symbol, PERIOD_M1, 0);
   if(t == 0 || t == g_lastBarTime)
      return(false);
   g_lastBarTime = t;
   return(true);
  }

int TrendBias()
  {
   double f[], s[];
   ArraySetAsSeries(f, true);
   ArraySetAsSeries(s, true);
   if(CopyBuffer(hTrendFast, 0, 1, 4, f) != 4 || CopyBuffer(hTrendSlow, 0, 1, 1, s) != 1)
      return(0);
   double c = iClose(_Symbol, InpTrendTF, 1);
   if(c <= 0)
      return(0);
   if(f[0] > s[0] && c > f[0] && f[0] > f[3]) return(1);
   if(f[0] < s[0] && c < f[0] && f[0] < f[3]) return(-1);
   return(0);
  }

void RefreshIndicatorCache()
  {
   double a[];
   ArraySetAsSeries(a, true);
   if(CopyBuffer(hAtr, 0, 1, 1, a) == 1) g_atr = a[0];
   if(CopyBuffer(hAdx, 0, 1, 1, a) == 1) g_adx = a[0];
   g_bias = TrendBias();
  }

// Daily VWAP (anchored at server midnight), tick-volume weighted
void UpdateVWAP()
  {
   g_vwap = 0;
   g_vwapBars = 0;
   datetime t1 = iTime(_Symbol, PERIOD_M1, 1);
   if(t1 < g_dayStart)
      return;
   MqlRates rr[];
   int n = CopyRates(_Symbol, PERIOD_M1, g_dayStart, t1, rr);
   if(n <= 0)
      return;
   double pv = 0, v = 0;
   for(int i = 0; i < n; i++)
     {
      double vol = (double)MathMax(rr[i].tick_volume, (long)1);
      pv += (rr[i].high + rr[i].low + rr[i].close) / 3.0 * vol;
      v  += vol;
     }
   if(v > 0)
     {
      g_vwap = pv / v;
      g_vwapBars = n;
     }
  }

void UpdateOpeningRanges()
  {
   for(int i = 0; i < 2; i++)
     {
      if((i == 0 && !InpTradeLondon) || (i == 1 && !InpTradeNewYork))
         continue;
      datetime st = ORStartServer(i);
      if(g_or[i].start != st)
        {
         g_or[i].start       = st;
         g_or[i].hi          = 0;
         g_or[i].lo          = 0;
         g_or[i].ready       = false;
         g_or[i].tradedLong  = false;
         g_or[i].tradedShort = false;
        }
      datetime orEnd = st + InpORMinutes * 60;
      if(g_or[i].ready || g_server < orEnd)
         continue;
      MqlRates rr[];
      int n = CopyRates(_Symbol, PERIOD_M1, st, orEnd - 1, rr);
      if(n < MathMax(3, InpORMinutes / 2))
         continue;
      double hi = rr[0].high, lo = rr[0].low;
      for(int k = 1; k < n; k++)
        {
         hi = MathMax(hi, rr[k].high);
         lo = MathMin(lo, rr[k].low);
        }
      g_or[i].hi    = hi;
      g_or[i].lo    = lo;
      g_or[i].ready = true;
      Log(StringFormat("%s opening range ready: %s - %s", (i == 0 ? "London" : "New York"),
                       DoubleToString(lo, _Digits), DoubleToString(hi, _Digits)));
     }
  }

//+------------------------------------------------------------------+
//| News filter (MQL5 economic calendar, live only)                  |
//+------------------------------------------------------------------+
void LoadNews()
  {
   if(g_newsLoaded > 0 && TimeTradeServer() - g_newsLoaded < 600)
      return;
   g_newsLoaded = TimeTradeServer();
   ArrayResize(g_newsTimes, 0);
   ArrayResize(g_newsNames, 0);
   string cur[];
   int nc = StringSplit(InpNewsCurrencies, ',', cur);
   datetime from = g_newsLoaded - 3600;
   datetime to   = g_newsLoaded + 2 * 86400;
   for(int c = 0; c < nc; c++)
     {
      string ccy = cur[c];
      StringTrimLeft(ccy);
      StringTrimRight(ccy);
      StringToUpper(ccy);
      if(ccy == "")
         continue;
      MqlCalendarValue vals[];
      int n = CalendarValueHistory(vals, from, to, NULL, ccy);
      for(int i = 0; i < n; i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(vals[i].event_id, ev))
            continue;
         bool important = (ev.importance == CALENDAR_IMPORTANCE_HIGH) ||
                          (InpNewsIncludeMedium && ev.importance == CALENDAR_IMPORTANCE_MODERATE);
         if(!important)
            continue;
         int sz = ArraySize(g_newsTimes);
         ArrayResize(g_newsTimes, sz + 1);
         ArrayResize(g_newsNames, sz + 1);
         g_newsTimes[sz] = vals[i].time;
         g_newsNames[sz] = ccy + " " + ev.name;
        }
     }
  }

bool NewsBlocked(string &what)
  {
   if(!InpUseNews || IsTester())
      return(false);
   LoadNews();
   datetime now = TimeTradeServer();
   for(int i = 0; i < ArraySize(g_newsTimes); i++)
     {
      if(now >= g_newsTimes[i] - InpNewsMinsBefore * 60 && now <= g_newsTimes[i] + InpNewsMinsAfter * 60)
        {
         what = g_newsNames[i];
         return(true);
        }
     }
   return(false);
  }

string NextNewsText()
  {
   if(!InpUseNews)  return("off");
   if(IsTester())   return("n/a in tester");
   LoadNews();
   datetime now = TimeTradeServer(), best = 0;
   string name = "";
   for(int i = 0; i < ArraySize(g_newsTimes); i++)
      if(g_newsTimes[i] > now && (best == 0 || g_newsTimes[i] < best))
        {
         best = g_newsTimes[i];
         name = g_newsNames[i];
        }
   if(best == 0) return("none in next 48h");
   if(StringLen(name) > 22) name = StringSubstr(name, 0, 22);
   return(name + " " + TimeToString(best, TIME_MINUTES));
  }

//+------------------------------------------------------------------+
//| Position sizing                                                   |
//+------------------------------------------------------------------+
double MoneyPerLot(const int dir, const double price, const double dist, const bool loss)
  {
   ENUM_ORDER_TYPE ot = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double target;
   if(loss) target = (dir > 0) ? price - dist : price + dist;
   else     target = (dir > 0) ? price + dist : price - dist;
   double p = 0;
   if(OrderCalcProfit(ot, _Symbol, 1.0, price, target, p) && p != 0)
      return(MathAbs(p));
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(ts <= 0)
      return(0);
   return(dist / ts * tv);
  }

// Never boosts while the week or the day is red (no martingale)
double PaceMultiplier()
  {
   if(InpWeeklyTarget <= 0 || InpPaceBoostMax <= 1.0)
      return(1.0);
   if(g_weekClosed < 0 || g_todayClosed < 0)
      return(1.0);
   int elapsed = 5 - TradingDaysLeft();
   if(elapsed <= 0)
      return(1.0);
   double expected = InpWeeklyTarget * elapsed / 5.0;
   double behind   = expected - g_weekClosed;
   if(behind <= 0)
      return(1.0);
   double frac = MathMin(behind / (InpWeeklyTarget / 5.0), 1.0);
   return(1.0 + (InpPaceBoostMax - 1.0) * frac);
  }

double ComputeRiskMoney(const double lossPerLot, double &mult, double &cap, double &room)
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double base;
   switch(InpLotMode)
     {
      case LOT_FIXED:      base = InpFixedLot * lossPerLot;           break;
      case LOT_RISK_MONEY: base = InpRiskMoney;                       break;
      default:             base = equity * InpRiskPercent / 100.0;    break;
     }

   mult = 1.0;
   if(InpUseLossReduce && InpLossReduceAfter > 0 && g_consecLossWeek >= InpLossReduceAfter)
      mult = InpLossReduceFactor;
   else if(InpUsePaceBoost)
      mult = PaceMultiplier();

   double risk = base * mult;
   if(InpUseHouseMoney && g_weekClosed > 0)
      risk += g_weekClosed * InpHouseMoneyPct / 100.0;

   cap = (InpMaxRiskPctCap > 0) ? equity * InpMaxRiskPctCap / 100.0 : DBL_MAX;
   room = DBL_MAX;
   if(InpDailyMaxLoss > 0)  room = MathMin(room, InpDailyMaxLoss  + g_todayClosed + g_floating);
   if(InpWeeklyMaxLoss > 0) room = MathMin(room, InpWeeklyMaxLoss + g_weekClosed  + g_floating);

   risk = MathMin(risk, MathMin(cap, room));
   return(MathMax(risk, 0.0));
  }

double CalcLots(const int dir, const double price, const double slDist, const double tpDist,
                double &riskMoney, double &mult)
  {
   double vMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(vStep <= 0) vStep = vMin;
   if(vStep <= 0) return(0);

   double lossPerLot = MoneyPerLot(dir, price, slDist, true) + InpCommissionPerLot;
   if(lossPerLot <= 0)
      return(0);

   double cap = 0, room = 0;
   riskMoney = ComputeRiskMoney(lossPerLot, mult, cap, room);
   if(riskMoney <= 0)
      return(0);

   double lots = riskMoney / lossPerLot;

   // Do not risk more than needed when the TP alone would complete the weekly target
   if(InpRightSizeNearGoal && InpStopOnWeeklyTarget && InpWeeklyTarget > 0)
     {
      double remaining    = InpWeeklyTarget - (g_weekClosed + g_floating);
      double profitPerLot = MoneyPerLot(dir, price, tpDist, false) - InpCommissionPerLot;
      if(remaining > 0 && profitPerLot > 0)
         lots = MathMin(lots, remaining * 1.15 / profitPerLot);
     }

   double maxLot = MathMin(InpMaxLot, vMax);
   lots = MathMin(lots, maxLot);
   lots = MathFloor(lots / vStep + 1e-9) * vStep;

   if(lots < vMin - 1e-9)
     {
      double minRisk = vMin * lossPerLot;
      if(vMin <= maxLot + 1e-9 && minRisk <= cap && minRisk <= room && minRisk <= riskMoney * 1.5)
         lots = vMin;
      else
         return(0);
     }

   double margin = 0;
   ENUM_ORDER_TYPE ot = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(OrderCalcMargin(ot, _Symbol, lots, price, margin) && margin > 0)
     {
      double freeM = AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.8;
      if(margin > freeM)
        {
         lots = MathFloor(lots * freeM / margin / vStep + 1e-9) * vStep;
         if(lots < vMin - 1e-9)
            return(0);
        }
     }

   riskMoney = lots * lossPerLot;
   return(NormalizeDouble(lots, VolumeDigits(vStep)));
  }

//+------------------------------------------------------------------+
//| Signals                                                           |
//+------------------------------------------------------------------+
void ResetSignal(Signal &s)
  {
   s.dir = 0; s.sl = 0; s.tp = 0; s.rr = 0; s.orIdx = -1; s.name = "";
  }

// 1) Trend pullback: HTF trend + ADX, M1 pullback into EMA21 with RSI reset, momentum resume
bool SignalTrendPullback(Signal &sig, const MqlRates &r[], const double &e9[], const double &e21[],
                         const double &e50[], const double &rs[], const double atr, const int bias,
                         const double adx)
  {
   if(bias == 0 || adx < InpAdxTrendMin)
      return(false);
   int lb = InpPullbackLookback;
   double rng = r[1].high - r[1].low;
   if(rng <= 0 || rng > 2.5 * atr)
      return(false);                                   // no chasing spike candles
   bool touched = false, dipped = false, broken = false;

   if(bias > 0 && DirAllowed(1))
     {
      if(!(e21[1] > e50[1] && e21[1] > e21[lb]))
         return(false);
      for(int k = 2; k <= lb + 1; k++)
        {
         if(r[k].low <= e21[k] + 0.15 * atr)   touched = true;
         if(rs[k] <= InpRsiPullbackLevel)        dipped  = true;
         if(r[k].close < e50[k])                 broken  = true;
        }
      bool trigger = r[1].close > r[1].open && r[1].close > e9[1] && r[1].close > r[2].high && rs[1] > 50.0;
      if(touched && dipped && !broken && trigger)
        {
         double lo = r[1].low;
         for(int k = 2; k <= 5; k++) lo = MathMin(lo, r[k].low);
         sig.dir = 1; sig.sl = lo - 0.2 * atr; sig.tp = 0; sig.rr = InpTrendRR; sig.name = "TrendPB";
         return(true);
        }
      return(false);
     }

   if(bias < 0 && DirAllowed(-1))
     {
      if(!(e21[1] < e50[1] && e21[1] < e21[lb]))
         return(false);
      for(int k = 2; k <= lb + 1; k++)
        {
         if(r[k].high >= e21[k] - 0.15 * atr)        touched = true;
         if(rs[k] >= 100.0 - InpRsiPullbackLevel)      dipped  = true;
         if(r[k].close > e50[k])                       broken  = true;
        }
      bool trigger = r[1].close < r[1].open && r[1].close < e9[1] && r[1].close < r[2].low && rs[1] < 50.0;
      if(touched && dipped && !broken && trigger)
        {
         double hi = r[1].high;
         for(int k = 2; k <= 5; k++) hi = MathMax(hi, r[k].high);
         sig.dir = -1; sig.sl = hi + 0.2 * atr; sig.tp = 0; sig.rr = InpTrendRR; sig.name = "TrendPB";
         return(true);
        }
     }
   return(false);
  }

// 2) London / New York opening-range breakout (one trade per side per session)
bool SignalBreakout(Signal &sig, const MqlRates &r[], const double atr, const int bias)
  {
   for(int i = 0; i < 2; i++)
     {
      if(!g_or[i].ready)
         continue;
      if((i == 0 && !InpTradeLondon) || (i == 1 && !InpTradeNewYork))
         continue;
      datetime orEnd = g_or[i].start + InpORMinutes * 60;
      if(r[1].time < orEnd || r[1].time > orEnd + InpBreakoutWindow * 60)
         continue;
      double h = g_or[i].hi - g_or[i].lo;
      if(h < InpORMinATR * atr || h > InpORMaxATR * atr)
         continue;
      double buf  = InpBreakBufferATR * atr;
      double mid  = (g_or[i].hi + g_or[i].lo) / 2.0;
      double rng1 = r[1].high - r[1].low;
      if(rng1 <= 0)
         continue;
      bool strong = MathAbs(r[1].close - r[1].open) >= 0.5 * rng1;
      string tag  = (i == 0) ? "LDN-ORB" : "NY-ORB";

      if(DirAllowed(1) && !g_or[i].tradedLong && strong && r[1].close > r[1].open &&
         r[1].close > g_or[i].hi + buf && r[2].close <= g_or[i].hi + buf &&
         (!InpBreakoutTrendFilter || bias >= 0))
        {
         sig.dir = 1; sig.sl = mid; sig.tp = 0; sig.rr = InpBreakoutRR; sig.orIdx = i; sig.name = tag;
         return(true);
        }
      if(DirAllowed(-1) && !g_or[i].tradedShort && strong && r[1].close < r[1].open &&
         r[1].close < g_or[i].lo - buf && r[2].close >= g_or[i].lo - buf &&
         (!InpBreakoutTrendFilter || bias <= 0))
        {
         sig.dir = -1; sig.sl = mid; sig.tp = 0; sig.rr = InpBreakoutRR; sig.orIdx = i; sig.name = tag;
         return(true);
        }
     }
   return(false);
  }

// 3) VWAP mean reversion in ranging regime: stretched price + RSI extreme + rejection candle
bool SignalVwap(Signal &sig, const MqlRates &r[], const double &rs[], const double atr,
                const double adx, const int bias)
  {
   if(g_vwap <= 0 || g_vwapBars < InpVwapMinBars)
      return(false);
   if(adx < 0 || adx > InpAdxRangeMax)
      return(false);
   double rng = r[1].high - r[1].low;
   if(rng <= 0)
      return(false);
   double dev       = r[1].close - g_vwap;
   double priorLow  = MathMin(MathMin(r[3].low, r[4].low), MathMin(r[5].low, r[6].low));
   double priorHigh = MathMax(MathMax(r[3].high, r[4].high), MathMax(r[5].high, r[6].high));

   if(DirAllowed(1) && (InpVwapCounterTrend || bias >= 0) && dev <= -InpVwapDevATR * atr)
     {
      double wick = MathMin(r[1].open, r[1].close) - r[1].low;
      bool os     = MathMin(rs[1], rs[2]) <= InpRsiOversold;
      bool rej    = r[1].close > r[1].open && wick >= 0.35 * rng;
      bool swing  = MathMin(r[1].low, r[2].low) < priorLow;
      if(os && rej && swing)
        {
         sig.dir = 1; sig.sl = MathMin(r[1].low, r[2].low) - 0.3 * atr;
         sig.tp = g_vwap - 0.1 * atr; sig.rr = 0; sig.name = "VWAP-Rev";
         return(true);
        }
     }
   if(DirAllowed(-1) && (InpVwapCounterTrend || bias <= 0) && dev >= InpVwapDevATR * atr)
     {
      double wick = r[1].high - MathMax(r[1].open, r[1].close);
      bool ob     = MathMax(rs[1], rs[2]) >= 100.0 - InpRsiOversold;
      bool rej    = r[1].close < r[1].open && wick >= 0.35 * rng;
      bool swing  = MathMax(r[1].high, r[2].high) > priorHigh;
      if(ob && rej && swing)
        {
         sig.dir = -1; sig.sl = MathMax(r[1].high, r[2].high) + 0.3 * atr;
         sig.tp = g_vwap + 0.1 * atr; sig.rr = 0; sig.name = "VWAP-Rev";
         return(true);
        }
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Gatekeeping                                                       |
//+------------------------------------------------------------------+
bool CanOpenNewTrade(string &reason)
  {
   int d = DowOf(g_server);
   if(d == 0 || d == 6) { reason = "Weekend"; return(false); }
   if(!IsTester() && (MQLInfoInteger(MQL_TRADE_ALLOWED) == 0 || TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) == 0))
     { reason = "Algo Trading is disabled"; return(false); }
   long tm = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tm == SYMBOL_TRADE_MODE_DISABLED || tm == SYMBOL_TRADE_MODE_CLOSEONLY)
     { reason = "Symbol not tradable"; return(false); }

   int why = 0;
   if(IsWeekLocked(why))
     {
      reason = (why == LOCK_TARGET) ? "WEEKLY TARGET HIT - done for the week" : "Weekly loss limit - wait for next week";
      return(false);
     }
   if(IsDayLocked(why))
     {
      if(why == LOCK_TARGET)  reason = "Daily goal hit - done for today";
      else if(why == LOCK_DD) reason = "Equity guard - paused today";
      else                    reason = "Daily loss limit - paused today";
      return(false);
     }
   if(FridayCutoff()) { reason = "Friday cutoff - flat for weekend"; return(false); }
   if(InpMaxConsecLossesDay > 0 && g_consecLossToday >= InpMaxConsecLossesDay)
     { reason = IntegerToString(g_consecLossToday) + " losses in a row - paused today"; return(false); }
   if(InpMaxTradesPerDay > 0 && g_tradesToday >= InpMaxTradesPerDay)
     { reason = "Max trades for today"; return(false); }

   string ses = ActiveSession();
   g_session = ses;
   if(ses == "") { reason = "Outside sessions"; return(false); }
   if(g_openCount >= InpMaxOpenPositions) { reason = "In trade (" + ses + ")"; return(false); }
   if(InpCooldownMinutes > 0 && g_lastExitLoss && (long)(g_server - g_lastExitTime) < (long)InpCooldownMinutes * 60)
     { reason = "Cooldown after loss"; return(false); }
   if(InpMinMinutesBetween > 0 && g_lastEntryTime > 0 &&
      (long)(g_server - g_lastEntryTime) < (long)InpMinMinutesBetween * 60)
     { reason = "Spacing between trades"; return(false); }
   string ev = "";
   if(NewsBlocked(ev)) { reason = "News: " + ev; return(false); }

   reason = "Scanning (" + ses + ")";
   return(true);
  }

//+------------------------------------------------------------------+
//| Execution                                                         |
//+------------------------------------------------------------------+
bool OpenTrade(Signal &sig, const double atr)
  {
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return(false);
   double price    = (sig.dir > 0) ? tk.ask : tk.bid;
   double spread   = tk.ask - tk.bid;
   double stopsLvl = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double minSL    = MathMax(InpMinSL_ATR * atr, MathMax(3.0 * spread, stopsLvl + spread + _Point));
   double maxSL    = InpMaxSL_ATR * atr;
   if(maxSL < minSL)
     {
      Log(sig.name + " skipped: spread/stops level too large for the ATR stop range");
      return(false);
     }

   double slDist = (sig.dir > 0) ? price - sig.sl : sig.sl - price;
   if(slDist < minSL) slDist = minSL;
   if(slDist > maxSL) slDist = maxSL;

   double tpDist;
   if(sig.tp > 0)
     {
      tpDist = (sig.dir > 0) ? sig.tp - price : price - sig.tp;
      if(tpDist < InpVwapMinRR * slDist)
        {
         Log(sig.name + " skipped: reward to VWAP too small");
         return(false);
        }
      tpDist = MathMin(tpDist, InpVwapMaxRR * slDist);
     }
   else
      tpDist = sig.rr * slDist;
   tpDist = MathMax(tpDist, stopsLvl + _Point);

   double riskMoney = 0, mult = 1.0;
   double lots = CalcLots(sig.dir, price, slDist, tpDist, riskMoney, mult);
   if(lots <= 0)
     {
      Log(sig.name + " skipped: lot below broker minimum for the allowed risk (cap / loss-limit room)");
      return(false);
     }

   string cmt = InpComment + " " + sig.name;
   if(StringLen(cmt) > 31) cmt = StringSubstr(cmt, 0, 31);

   bool   done = false;
   double sl = 0, tp = 0;
   for(int attempt = 0; attempt < 3; attempt++)
     {
      if(attempt > 0)
        {
         Sleep(250);
         if(!SymbolInfoTick(_Symbol, tk)) break;
         price = (sig.dir > 0) ? tk.ask : tk.bid;
        }
      sl = NormalizePrice((sig.dir > 0) ? price - slDist : price + slDist);
      tp = NormalizePrice((sig.dir > 0) ? price + tpDist : price - tpDist);
      bool sent = (sig.dir > 0) ? trade.Buy(lots, _Symbol, price, sl, tp, cmt)
                                : trade.Sell(lots, _Symbol, price, sl, tp, cmt);
      uint rc = trade.ResultRetcode();
      if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED))
        {
         done = true;
         break;
        }
      PrintFormat("%s: order failed (%u %s)", EA_NAME, rc, trade.ResultRetcodeDescription());
      if(rc != TRADE_RETCODE_REQUOTE && rc != TRADE_RETCODE_PRICE_CHANGED && rc != TRADE_RETCODE_PRICE_OFF)
         break;
     }
   if(!done)
      return(false);

   ulong posId = 0;
   ulong deal  = trade.ResultDeal();
   if(deal > 0 && HistoryDealSelect(deal))
      posId = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   if(posId == 0)
      posId = trade.ResultOrder();
   double fill = trade.ResultPrice();
   if(fill <= 0) fill = price;
   double realR = MathAbs(fill - sl);
   if(realR <= 0) realR = slDist;
   if(posId > 0)
      GlobalVariableSet(GVPos("R", posId), realR);

   g_lastEntryTime = TimeCurrent();
   g_lastRisk      = riskMoney;
   g_lastMult      = mult;
   g_statsDirty    = true;
   g_lastSignal    = sig.name + (sig.dir > 0 ? " BUY " : " SELL ") + DoubleToString(lots, 2) +
                     " @ " + DoubleToString(fill, _Digits);
   PrintFormat("%s: %s %s %.2f lots @ %s | SL %s TP %s | risk %.2f (x%.2f) | ATR %.2f | week %s / %.2f",
               EA_NAME, sig.name, (sig.dir > 0 ? "BUY" : "SELL"), lots, DoubleToString(fill, _Digits),
               DoubleToString(sl, _Digits), DoubleToString(tp, _Digits), riskMoney, mult, atr,
               Money(g_weekClosed + g_floating), InpWeeklyTarget);
   return(true);
  }

bool ClosePartial(const ulong ticket, const bool isBuy, const double vol, const double sl, const double tp)
  {
   if(IsHedging())
      return(trade.PositionClosePartial(ticket, vol));
   // Netting account: reduce the position with an opposite deal, then restore SL/TP
   bool ok = isBuy ? trade.Sell(vol, _Symbol, 0.0, 0.0, 0.0, InpComment + " partial")
                   : trade.Buy(vol, _Symbol, 0.0, 0.0, 0.0, InpComment + " partial");
   if(ok && PositionSelectByTicket(ticket))
      trade.PositionModify(ticket, sl, tp);
   return(ok);
  }

void CloseAll(const string why)
  {
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(trade.PositionClose(t)) closed++;
     }
   if(closed > 0)
      Notify(why + " - closed " + IntegerToString(closed) + " position(s)");
   g_statsDirty = true;
  }

double InitialRisk(const ulong ticket, const double open, const double sl, const double atr)
  {
   string k = GVPos("R", ticket);
   if(GlobalVariableCheck(k))
      return(GlobalVariableGet(k));
   // Unknown position (e.g. restarted after BE move): fall back to a sane ATR-based R
   double r = (sl > 0) ? MathAbs(open - sl) : 0.0;
   if(r < InpMinSL_ATR * atr)
      r = InpMinSL_ATR * atr;
   if(r > 0)
      GlobalVariableSet(k, r);
   return(r);
  }

void ManagePositions()
  {
   if(g_openCount == 0)
      return;
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return;
   double atr     = g_atr;
   double lvl     = (double)MathMax(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                                    SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)) * _Point;
   double vMin    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(vStep <= 0) vStep = vMin;
   double minStep = MathMax(0.05 * atr, 5 * _Point);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      bool     isBuy  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double   open   = PositionGetDouble(POSITION_PRICE_OPEN);
      double   sl     = PositionGetDouble(POSITION_SL);
      double   tp     = PositionGetDouble(POSITION_TP);
      double   vol    = PositionGetDouble(POSITION_VOLUME);
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      double   R      = InitialRisk(ticket, open, sl, atr);
      double   cur    = isBuy ? tk.bid : tk.ask;
      double   prof   = isBuy ? cur - open : open - cur;

      // 1) Time stop - a scalp that has not worked out quickly is closed
      if(InpMaxHoldMinutes > 0 && (long)(TimeCurrent() - opened) >= (long)InpMaxHoldMinutes * 60)
        {
         if(trade.PositionClose(ticket))
            Log("Time stop closed #" + IntegerToString((long)ticket));
         continue;
        }
      if(R <= 0)
         continue;

      // 2) Partial take profit
      if(InpUsePartial && prof >= InpPartialR * R && !GlobalVariableCheck(GVPos("P", ticket)))
        {
         double cv = MathFloor(vol * InpPartialPct / 100.0 / vStep + 1e-9) * vStep;
         cv = NormalizeDouble(cv, VolumeDigits(vStep));
         if(cv >= vMin - 1e-9 && (vol - cv) >= vMin - 1e-9)
           {
            if(ClosePartial(ticket, isBuy, cv, sl, tp))
              {
               GlobalVariableSet(GVPos("P", ticket), 1);
               Log("Partial TP " + DoubleToString(cv, 2) + " lots on #" + IntegerToString((long)ticket));
              }
           }
         else
            GlobalVariableSet(GVPos("P", ticket), 1);   // volume too small to split
        }

      // 3) Break-even and ATR trailing
      double newSL = sl;
      if(InpUseBreakEven && prof >= InpBE_TriggerR * R)
        {
         double be = isBuy ? open + InpBE_LockR * R : open - InpBE_LockR * R;
         if(isBuy ? (newSL == 0 || be > newSL) : (newSL == 0 || be < newSL))
            newSL = be;
        }
      if(InpUseTrailing && atr > 0 && prof >= InpTrailStartR * R)
        {
         double trl = isBuy ? cur - InpTrailATR * atr : cur + InpTrailATR * atr;
         if(isBuy ? (newSL == 0 || trl > newSL) : (newSL == 0 || trl < newSL))
            newSL = trl;
        }
      if(newSL != sl)
        {
         newSL = NormalizePrice(newSL);
         bool better = isBuy ? (sl == 0 || newSL >= sl + minStep) : (sl == 0 || newSL <= sl - minStep);
         bool legal  = isBuy ? (tk.bid - newSL > lvl) : (newSL - tk.ask > lvl);
         if(better && legal && !trade.PositionModify(ticket, newSL, tp))
            Log("Modify failed #" + IntegerToString((long)ticket) + ": " + trade.ResultRetcodeDescription());
        }
     }
  }

//+------------------------------------------------------------------+
//| Protection: targets, loss limits, equity guard, Friday close     |
//+------------------------------------------------------------------+
void ProtectionChecks()
  {
   double weekNet = g_weekClosed + g_floating;
   double dayNet  = g_todayClosed + g_floating;
   int wWhy = 0, dWhy = 0;
   bool wLocked = IsWeekLocked(wWhy);
   bool dLocked = IsDayLocked(dWhy);

   // Weekly target
   if(InpStopOnWeeklyTarget && InpWeeklyTarget > 0 && !wLocked && weekNet >= InpWeeklyTarget)
     {
      if(InpCloseOnWeeklyTarget && g_openCount > 0)
         CloseAll("Weekly target reached");
      LockWeek(LOCK_TARGET);
      g_weekHitFlag = true;
      Notify("WEEKLY TARGET HIT " + Money(weekNet) + " / " + DoubleToString(InpWeeklyTarget, 2) +
             " - trading paused until next week");
      return;
     }

   // Weekly loss limit
   if(InpWeeklyMaxLoss > 0 && weekNet <= -InpWeeklyMaxLoss)
     {
      if(g_openCount > 0)
         CloseAll("Weekly max loss");
      if(!wLocked)
        {
         LockWeek(LOCK_LOSS);
         Notify("Weekly loss limit hit " + Money(weekNet) + " - paused until next week");
        }
      return;
     }

   // Daily loss limit
   if(InpDailyMaxLoss > 0 && dayNet <= -InpDailyMaxLoss)
     {
      if(g_openCount > 0)
         CloseAll("Daily max loss");
      if(!dLocked)
        {
         LockDay(LOCK_LOSS);
         Notify("Daily loss limit hit " + Money(dayNet) + " - paused until tomorrow");
        }
      return;
     }

   // Equity guard (whole account floating drawdown)
   if(InpMaxEquityDDPct > 0 && g_openCount > 0)
     {
      double bal = AccountInfoDouble(ACCOUNT_BALANCE);
      double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
      if(bal > 0 && (bal - eq) / bal * 100.0 >= InpMaxEquityDDPct)
        {
         CloseAll("Equity drawdown guard");
         if(!dLocked) LockDay(LOCK_DD);
         return;
        }
     }

   // Daily pace goal
   if(InpStopOnDailyTarget && !dLocked && !wLocked)
     {
      double dt = DailyTarget();
      if(dt > 0 && dayNet >= dt)
        {
         if(InpCloseOnDailyTarget && g_openCount > 0)
            CloseAll("Daily goal reached");
         LockDay(LOCK_TARGET);
         Notify("Daily goal hit " + Money(dayNet) + " / " + DoubleToString(dt, 2) + " - done for today");
         return;
        }
     }

   // Weekend
   if(g_openCount > 0 && FridayCutoff())
      CloseAll("Friday cutoff - flat for the weekend");
  }

//+------------------------------------------------------------------+
//| Entry evaluation (once per closed M1 bar)                         |
//+------------------------------------------------------------------+
void EvaluateEntries()
  {
   string reason = "";
   if(!CanOpenNewTrade(reason))
      return;

   double atr = g_atr;
   if(atr <= 0)
      return;
   if(atr < InpMinATR_USD) { g_filterNote = "ATR too low (dead market)"; return; }
   if(atr > InpMaxATR_USD) { g_filterNote = "ATR too high (spike)";      return; }

   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return;
   double spread = tk.ask - tk.bid;
   if(spread > InpMaxSpreadUSD || spread > InpMaxSpreadATRFrac * atr)
     {
      g_filterNote = "Spread too wide (" + DoubleToString(spread, _Digits) + ")";
      return;
     }
   g_filterNote = "";

   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, PERIOD_M1, 0, 30, r) < 30)
      return;
   double e9[], e21[], e50[], rs[];
   ArraySetAsSeries(e9, true);
   ArraySetAsSeries(e21, true);
   ArraySetAsSeries(e50, true);
   ArraySetAsSeries(rs, true);
   if(CopyBuffer(hEmaFast, 0, 0, 30, e9) < 30 || CopyBuffer(hEmaMid, 0, 0, 30, e21) < 30 ||
      CopyBuffer(hEmaSlow, 0, 0, 30, e50) < 30 || CopyBuffer(hRsi, 0, 0, 30, rs) < 30)
      return;

   Signal sig;
   ResetSignal(sig);
   bool got = false;
   if(InpUseBreakout)
      got = SignalBreakout(sig, r, atr, g_bias);
   if(!got && InpUseTrendPullback)
      got = SignalTrendPullback(sig, r, e9, e21, e50, rs, atr, g_bias, g_adx);
   if(!got && InpUseVwap)
      got = SignalVwap(sig, r, rs, atr, g_adx, g_bias);
   if(!got)
      return;

   // never hedge / net against our own open trade
   if((sig.dir > 0 && g_hasSell) || (sig.dir < 0 && g_hasBuy))
      return;

   if(OpenTrade(sig, atr) && sig.orIdx >= 0)
     {
      if(sig.dir > 0) g_or[sig.orIdx].tradedLong  = true;
      else            g_or[sig.orIdx].tradedShort = true;
     }
  }

//+------------------------------------------------------------------+
//| Dashboard                                                         |
//+------------------------------------------------------------------+
string g_pl[];
color  g_pc[];
int    g_pn = 0;

void PanelLine(const string text, const color clr)
  {
   ArrayResize(g_pl, g_pn + 1);
   ArrayResize(g_pc, g_pn + 1);
   g_pl[g_pn] = text;
   g_pc[g_pn] = clr;
   g_pn++;
  }

void SetLabel(const string name, const int x, const int y, const string text, const color clr)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
     }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }

void DrawPanel()
  {
   if(!InpShowPanel)
      return;
   if(IsTester() && MQLInfoInteger(MQL_VISUAL_MODE) == 0)
      return;

   string reason = "";
   bool   can    = CanOpenNewTrade(reason);
   double weekNet = g_weekClosed + g_floating;
   double dayNet  = g_todayClosed + g_floating;
   double prog    = (InpWeeklyTarget > 0) ? weekNet / InpWeeklyTarget : 0.0;
   double goal    = DailyTarget();
   int    wl      = g_weekWins + g_weekLosses;
   double wr      = (wl > 0) ? 100.0 * g_weekWins / wl : 0.0;
   MqlTick tk;
   ZeroMemory(tk);
   SymbolInfoTick(_Symbol, tk);
   double spread = tk.ask - tk.bid;

   // risk preview for a typical 1.5 ATR stop
   double mult = 1.0, cap = 0, room = 0, risk = 0;
   if(g_atr > 0 && tk.ask > 0)
     {
      double lpl = MoneyPerLot(1, tk.ask, 1.5 * g_atr, true) + InpCommissionPerLot;
      risk = ComputeRiskMoney(lpl, mult, cap, room);
     }
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);

   g_pn = 0;
   PanelLine(EA_NAME + "  v" + EA_VER, clrGold);
   PanelLine("-------------------------------------------", clrDimGray);
   PanelLine("Status  : " + reason, can ? clrLimeGreen : clrOrange);
   if(g_filterNote != "" && can)
      PanelLine("Filter  : " + g_filterNote, clrOrange);
   PanelLine("Week    : " + Money(weekNet) + " / " + DoubleToString(InpWeeklyTarget, 2) +
             "  (" + DoubleToString(prog * 100.0, 0) + "%)", weekNet >= 0 ? clrLimeGreen : clrTomato);
   PanelLine("          " + ProgressBar(prog, 24), weekNet >= InpWeeklyTarget ? clrGold : clrDodgerBlue);
   PanelLine("Today   : " + Money(dayNet) + "  | goal " + DoubleToString(goal, 2), dayNet >= 0 ? clrLimeGreen : clrTomato);
   PanelLine("Floating: " + Money(g_floating) + "  | open " + IntegerToString(g_openCount), clrWhite);
   PanelLine("Trades  : " + IntegerToString(g_tradesToday) + " today | W/L " + IntegerToString(g_weekWins) + "/" +
             IntegerToString(g_weekLosses) + " (" + DoubleToString(wr, 0) + "%)", clrWhite);
   PanelLine("Risk    : " + DoubleToString(risk, 2) + " (" + DoubleToString(eq > 0 ? risk / eq * 100.0 : 0.0, 2) +
             "%) x" + DoubleToString(mult, 2) + " | streak " + IntegerToString(g_consecLossWeek) + "L", clrWhite);
   PanelLine("Market  : spr " + DoubleToString(spread, _Digits) + " | ATR " + DoubleToString(g_atr, 2) +
             " | ADX " + DoubleToString(g_adx, 1), clrSilver);
   PanelLine("Bias    : " + (g_bias > 0 ? "UP" : (g_bias < 0 ? "DOWN" : "FLAT")) + " (" + EnumToString(InpTrendTF) +
             ") | VWAP " + DoubleToString(g_vwap, _Digits), clrSilver);
   PanelLine("Clock   : GMT" + (g_gmtOffsetSec >= 0 ? "+" : "") + DoubleToString(g_gmtOffsetSec / 3600.0, 1) +
             " | LDN " + TimeToString(LondonLocal(), TIME_MINUTES) + " | NY " + TimeToString(NYLocal(), TIME_MINUTES), clrSilver);
   PanelLine("News    : " + NextNewsText(), clrSilver);
   PanelLine("Last    : " + g_lastSignal, clrSilver);

   string bg = OBJ_PREFIX + "bg";
   if(ObjectFind(0, bg) < 0)
     {
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, 8);
      ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, 22);
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, 360);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'16,20,28');
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_COLOR, C'60,70,90');
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
     }
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, g_pn * 16 + 12);

   for(int i = 0; i < g_pn; i++)
      SetLabel(OBJ_PREFIX + "L" + IntegerToString(i), 16, 28 + i * 16, g_pl[i], g_pc[i]);
   for(int i = g_pn; i < 24; i++)
      ObjectDelete(0, OBJ_PREFIX + "L" + IntegerToString(i));
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Housekeeping                                                      |
//+------------------------------------------------------------------+
void CleanupGVs()
  {
   g_lastGVClean = TimeCurrent();
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
     {
      string n = GlobalVariableName(i);
      if(StringFind(n, OBJ_PREFIX + "R_") != 0 && StringFind(n, OBJ_PREFIX + "P_") != 0)
         continue;
      ulong t = (ulong)StringToInteger(StringSubstr(n, StringLen(OBJ_PREFIX) + 2));
      if(t > 0 && !PositionSelectByTicket(t))
         GlobalVariableDel(n);
     }
  }

void PrintStartupSummary()
  {
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double pct = (eq > 0) ? InpWeeklyTarget / eq * 100.0 : 0.0;
   PrintFormat("%s v%s on %s | equity %.2f %s | weekly target %.2f = %.2f%% of equity | broker GMT%s%.1f",
               EA_NAME, EA_VER, _Symbol, eq, AccountInfoString(ACCOUNT_CURRENCY), InpWeeklyTarget, pct,
               (g_gmtOffsetSec >= 0 ? "+" : ""), g_gmtOffsetSec / 3600.0);
   PrintFormat("Sessions today (server time): London OR %s | New York OR %s",
               TimeToString(ORStartServer(0), TIME_MINUTES), TimeToString(ORStartServer(1), TIME_MINUTES));
   if(pct > 10.0)
      Print("WARNING: weekly target is above 10% of equity per week. That needs very high risk and is likely to "
            "end in large drawdowns. Use a bigger account or a smaller target.");
   else if(pct > 5.0)
      Print("NOTE: weekly target is 5-10% of equity per week - aggressive. Expect losing weeks.");
  }

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   string up = _Symbol;
   StringToUpper(up);
   if(StringFind(up, "XAU") < 0 && StringFind(up, "GOLD") < 0)
      PrintFormat("%s: WARNING - built for XAUUSD / GOLD, attached to %s", EA_NAME, _Symbol);
   if(_Period != PERIOD_M1)
      PrintFormat("%s: chart is not M1 - signals are still calculated on M1 internally.", EA_NAME);

   if(!ParseRange(InpLondonSession, g_lonFrom, g_lonTo) || !ParseRange(InpNYSession, g_nyFrom, g_nyTo) ||
      !ParseRange(InpAsiaSessionGMT, g_asFrom, g_asTo))
     {
      Print(EA_NAME, ": invalid session format - use HH:MM-HH:MM");
      return(INIT_PARAMETERS_INCORRECT);
     }
   g_lonOR    = ParseHHMM(InpLondonORStart);
   g_nyOR     = ParseHHMM(InpNYORStart);
   g_friClose = ParseHHMM(InpFridayCloseNY);
   if(g_lonOR < 0 || g_nyOR < 0 || g_friClose < 0)
     {
      Print(EA_NAME, ": invalid time format - use HH:MM");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpPullbackLookback < 2 || InpPullbackLookback > 20 || InpMaxOpenPositions < 1 ||
      InpMinSL_ATR <= 0 || InpMaxSL_ATR < InpMinSL_ATR || InpORMinutes < 3 ||
      (InpLotMode == LOT_RISK_PERCENT && InpRiskPercent <= 0) ||
      (InpLotMode == LOT_RISK_MONEY && InpRiskMoney <= 0) ||
      (InpLotMode == LOT_FIXED && InpFixedLot <= 0))
     {
      Print(EA_NAME, ": invalid parameters (check lookback 2-20, SL ATR range, risk settings)");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(IsTester())
      GlobalVariablesDeleteAll(OBJ_PREFIX);     // clean state between optimisation passes
   else if(InpResetLocksOnStart)
      ClearLocks();

   hEmaFast   = iMA(_Symbol, PERIOD_M1, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hEmaMid    = iMA(_Symbol, PERIOD_M1, InpEmaMid, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow   = iMA(_Symbol, PERIOD_M1, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   hRsi       = iRSI(_Symbol, PERIOD_M1, InpRsiPeriod, PRICE_CLOSE);
   hAtr       = iATR(_Symbol, PERIOD_M1, InpAtrPeriod);
   hTrendFast = iMA(_Symbol, InpTrendTF, InpTrendEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hTrendSlow = iMA(_Symbol, InpTrendTF, InpTrendEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   hAdx       = iADX(_Symbol, InpRegimeTF, InpAdxPeriod);
   if(hEmaFast == INVALID_HANDLE || hEmaMid == INVALID_HANDLE || hEmaSlow == INVALID_HANDLE ||
      hRsi == INVALID_HANDLE || hAtr == INVALID_HANDLE || hTrendFast == INVALID_HANDLE ||
      hTrendSlow == INVALID_HANDLE || hAdx == INVALID_HANDLE)
     {
      Print(EA_NAME, ": failed to create indicator handles");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints((ulong)InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   for(int i = 0; i < 2; i++)
     {
      g_or[i].start = 0; g_or[i].hi = 0; g_or[i].lo = 0;
      g_or[i].ready = false; g_or[i].tradedLong = false; g_or[i].tradedShort = false;
     }

   g_lastBarTime = iTime(_Symbol, PERIOD_M1, 0);   // first evaluation on the next new bar
   RefreshTime();
   RefreshStats();
   UpdateFloating();
   RefreshIndicatorCache();
   UpdateVWAP();
   g_trackWeek = g_weekStart;

   EventSetTimer(1);
   PrintStartupSummary();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, OBJ_PREFIX);
   if(hEmaFast   != INVALID_HANDLE) IndicatorRelease(hEmaFast);
   if(hEmaMid    != INVALID_HANDLE) IndicatorRelease(hEmaMid);
   if(hEmaSlow   != INVALID_HANDLE) IndicatorRelease(hEmaSlow);
   if(hRsi       != INVALID_HANDLE) IndicatorRelease(hRsi);
   if(hAtr       != INVALID_HANDLE) IndicatorRelease(hAtr);
   if(hTrendFast != INVALID_HANDLE) IndicatorRelease(hTrendFast);
   if(hTrendSlow != INVALID_HANDLE) IndicatorRelease(hTrendSlow);
   if(hAdx       != INVALID_HANDLE) IndicatorRelease(hAdx);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Main loop                                                         |
//+------------------------------------------------------------------+
void OnTick()
  {
   RefreshTime();
   TrackWeekRollover();

   bool newBar = IsNewBar();
   if(newBar || g_atr <= 0)
     {
      RefreshIndicatorCache();
      g_statsDirty = true;          // also rolls daily counters over at midnight
     }

   UpdateFloating();
   if(g_statsDirty)
      RefreshStats();

   ProtectionChecks();
   ManagePositions();

   if(newBar)
     {
      UpdateVWAP();
      UpdateOpeningRanges();
      EvaluateEntries();
     }
  }

void OnTimer()
  {
   RefreshTime();
   UpdateFloating();
   if(g_statsDirty)
      RefreshStats();
   DrawPanel();
   if(!IsTester() && TimeCurrent() - g_lastGVClean > 3600)
      CleanupGVs();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
      g_statsDirty = true;
  }

//+------------------------------------------------------------------+
//| Tester: weekly-target hit-rate report + custom optimisation score |
//+------------------------------------------------------------------+
double OnTester()
  {
   if(g_trackWeek > 0)
     {
      RecordWeek(g_trackWeek, ClosedPL(g_trackWeek, TimeCurrent() + 1));
      g_trackWeek = 0;
     }
   double hitPct = (g_weeksTotal > 0) ? 100.0 * g_weeksHit / g_weeksTotal : 0.0;
   PrintFormat("=== %s: weekly target %.2f hit in %d of %d weeks (%.1f%%) | losing weeks %d | best %s | worst %s ===",
               EA_NAME, InpWeeklyTarget, g_weeksHit, g_weeksTotal, hitPct, g_weeksRed,
               Money(g_bestWeek), Money(g_worstWeek));
   double profit = TesterStatistics(STAT_PROFIT);
   double dd     = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   if(profit <= 0)
      return(0.0);
   // Custom criterion: % of weeks that hit target, penalised by relative equity drawdown
   return(hitPct * (1.0 - MathMin(dd, 100.0) / 100.0));
  }
//+------------------------------------------------------------------+
