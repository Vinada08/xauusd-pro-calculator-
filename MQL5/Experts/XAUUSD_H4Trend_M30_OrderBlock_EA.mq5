//+------------------------------------------------------------------+
//|                         XAUUSD_H4Trend_M30_OrderBlock_EA.mq5     |
//|                                                                  |
//|  XAUUSD swing EA                                                 |
//|   - H4 decides the direction (bullish = BUY only,                |
//|     bearish = SELL only, neutral = no trade)                     |
//|   - M30 entries ONLY on a retest of the LAST CONFIRMED           |
//|     order block (an OB is "confirmed" when the move away from    |
//|     it broke M30 market structure - BOS - with displacement)     |
//|   - Trades only inside one daily session window, e.g.            |
//|     13:00 -> 04:30 (next day). Every EA trade is force-closed    |
//|     at the session close time (default 04:30).                   |
//+------------------------------------------------------------------+
#property copyright   "xauusd-pro-calculator"
#property version     "1.00"
#property description "XAUUSD M30 swing EA: H4 trend filter + M30 confirmed order block entries."
#property description "Opens trades only inside the session window and closes ALL its trades at the session close time (default 04:30)."

#include <Trade\Trade.mqh>

//--- enums ----------------------------------------------------------
enum ENUM_TREND_MODE
  {
   TREND_EMA               = 0, // H4 EMA fast/slow + close filter
   TREND_STRUCTURE         = 1, // H4 market structure (last break of structure)
   TREND_EMA_AND_STRUCTURE = 2  // Both must agree (strictest, recommended)
  };

enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0, // Fixed lot
   LOT_RISK_PERCENT = 1  // Risk % of equity per trade
  };

enum ENUM_OB_ZONE
  {
   OB_ZONE_WICK = 0, // Full candle (high-low)
   OB_ZONE_BODY = 1  // Candle body only (open-close)
  };

enum ENUM_ENTRY_CONFIRM
  {
   CONFIRM_TOUCH         = 0, // Enter when an M30 candle touches the OB
   CONFIRM_REJECTION     = 1, // Touch + candle closes in trend direction past OB middle
   CONFIRM_CLOSE_OUTSIDE = 2  // Touch + candle closes back outside the OB (strongest)
  };

//--- inputs ---------------------------------------------------------
input group "=== Session window (EA trades only inside this window) ==="
input string InpSessionStart              = "13:00"; // Session start: first time a trade may open (HH:MM)
input string InpSessionClose              = "04:30"; // Session close: ALL EA trades are closed (HH:MM)
input int    InpNoEntryMinutesBeforeClose = 60;      // Do not open new trades X minutes before close
input int    InpTimeOffsetHours           = 0;       // Hours added to SERVER time to get the clock above (0 = server time)
input bool   InpFridayProtection          = true;    // Close before the weekend on Friday
input string InpFridayNoEntryTime         = "18:00"; // Friday: no new trades after (SERVER time)
input string InpFridayCloseTime           = "22:30"; // Friday: force close all trades (SERVER time)

input group "=== H4 trend filter ==="
input ENUM_TREND_MODE InpTrendMode       = TREND_EMA_AND_STRUCTURE; // How the H4 trend is decided
input int             InpH4FastEMA       = 50;   // H4 fast EMA
input int             InpH4SlowEMA       = 200;  // H4 slow EMA
input int             InpH4SwingStrength = 3;    // H4 swing strength (bars each side)
input int             InpH4Lookback      = 300;  // H4 bars scanned for structure

input group "=== M30 order block ==="
input int                InpM30SwingStrength = 3;     // M30 swing strength (bars each side)
input int                InpOBLookbackBars   = 120;   // Max age of the BOS that confirms the OB (M30 bars)
input int                InpOBSearchBars     = 10;    // Bars before the BOS searched for the OB candle
input double             InpMinImpulseATR    = 1.5;   // Displacement: impulse away from OB >= X * ATR
input ENUM_OB_ZONE       InpOBZone           = OB_ZONE_WICK;     // OB zone definition
input bool               InpFreshOBOnly      = true;  // Trade only the FIRST retest of the OB
input ENUM_ENTRY_CONFIRM InpConfirm          = CONFIRM_REJECTION; // Entry confirmation on M30 close
input int                InpATRPeriod        = 14;    // ATR period (M30)

input group "=== Risk ==="
input ENUM_LOT_MODE InpLotMode            = LOT_RISK_PERCENT; // Lot sizing mode
input double        InpFixedLot           = 0.01; // Fixed lot (if fixed mode)
input double        InpRiskPercent        = 1.0;  // Risk % of equity per trade (if risk mode)
input double        InpRewardRisk         = 2.7;  // Final take profit = X * stop distance (R:R)
input int           InpSLBufferPoints     = 100;  // SL buffer beyond the OB wick (points)
input double        InpSLBufferATR        = 0.5;  // + extra SL buffer = X * ATR(M30) (0 = off)
input int           InpMinSLPoints        = 300;  // Minimum SL distance (points)
input int           InpMaxSLPoints        = 5000; // Maximum SL distance, skip trade if larger (points)
input int           InpMaxSpreadPoints    = 60;   // Max spread allowed to open (points)
input int           InpMaxTradesPerSession= 1;    // Max setups (entries) per session
input int           InpSlippagePoints     = 30;   // Max slippage (points)

input group "=== Two trades per setup (partial + runner) ==="
input bool   InpTwoTrades           = true; // Open 2 trades on each confirmed setup
input double InpTP1RR               = 1.0;  // Trade 1 (partial) take profit = X R
input double InpPartialLotPercent   = 50.0; // % of the total lot used for trade 1
input int    InpRunnerBELockPoints  = 20;   // Trade 2: SL to breakeven + X points when trade 1 TP is reached

input group "=== Trade management ==="
input bool   InpUseBreakeven        = true; // Single-trade mode: move SL to breakeven
input double InpBreakevenAtR        = 1.0;  // ...when profit reaches X R
input int    InpBreakevenLockPoints = 20;   // ...and lock this many points
input bool   InpUseTrailing         = false;// ATR trailing stop
input double InpTrailStartR         = 1.5;  // Start trailing at X R profit
input double InpTrailATRMult        = 2.0;  // Trail distance = X * ATR(M30)

input group "=== General ==="
input ulong  InpMagic     = 300430;     // Magic number
input string InpComment   = "H4M30_OB"; // Order comment
input bool   InpDrawOB    = true;       // Draw the active order block on the chart
input bool   InpShowPanel = true;       // Show info panel

//--- types / globals ------------------------------------------------
struct OrderBlock
  {
   bool     found;
   int      dir;      // +1 bullish (demand, BUY), -1 bearish (supply, SELL)
   double   zoneHi;
   double   zoneLo;
   double   wickHi;
   double   wickLo;
   datetime obTime;   // time of the OB candle
   datetime bosTime;  // time of the candle that confirmed it (BOS)
  };

CTrade     trade;
int        hFastEMA = INVALID_HANDLE;
int        hSlowEMA = INVALID_HANDLE;
int        hATR     = INVALID_HANDLE;

int        gStartMin, gCloseMin, gEntryEndMin, gFriNoEntryMin, gFriCloseMin;
datetime   gLastBarTime   = 0;
datetime   gLastTradedOB  = 0;   // one trade per order block
int        gTrend         = 0;
OrderBlock gOB;
string     gStatus        = "Starting...";
datetime   gLastCloseFail = 0;

const string OB_OBJ_NAME = "H4M30OB_ActiveZone";

string CommentPartial() { return InpComment + "_P"; }
string CommentRunner()  { return InpComment + "_R"; }

//+------------------------------------------------------------------+
//| Helpers: time                                                    |
//+------------------------------------------------------------------+
bool ParseHHMM(const string s, int &minutes)
  {
   string parts[];
   if(StringSplit(s, StringGetCharacter(":", 0), parts) != 2)
      return false;
   int h = (int)StringToInteger(parts[0]);
   int m = (int)StringToInteger(parts[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59)
      return false;
   minutes = h * 60 + m;
   return true;
  }

string MinToStr(const int m) { return StringFormat("%02d:%02d", m / 60, m % 60); }

datetime LocalNow() { return TimeCurrent() + InpTimeOffsetHours * 3600; }

int MinutesOfDay(const datetime t)
  {
   MqlDateTime d;
   TimeToStruct(t, d);
   return d.hour * 60 + d.min;
  }

// [start, end) on a 24h clock, wraps over midnight when start > end
bool InWindow(const int m, const int start, const int end)
  {
   if(start == end)
      return true;
   if(start < end)
      return (m >= start && m < end);
   return (m >= start || m < end);
  }

bool InHoldWindow()  { return InWindow(MinutesOfDay(LocalNow()), gStartMin, gCloseMin); }
bool InEntryWindow() { return InWindow(MinutesOfDay(LocalNow()), gStartMin, gEntryEndMin); }

bool FridayForceClose()
  {
   if(!InpFridayProtection)
      return false;
   MqlDateTime d;
   TimeToStruct(TimeCurrent(), d);
   if(d.day_of_week == 6 || d.day_of_week == 0)
      return true;
   return (d.day_of_week == 5 && d.hour * 60 + d.min >= gFriCloseMin);
  }

bool FridayNoEntry()
  {
   if(!InpFridayProtection)
      return false;
   MqlDateTime d;
   TimeToStruct(TimeCurrent(), d);
   if(d.day_of_week == 6 || d.day_of_week == 0)
      return true;
   return (d.day_of_week == 5 && d.hour * 60 + d.min >= gFriNoEntryMin);
  }

// Server time at which the current session started
datetime SessionStartServer()
  {
   datetime local    = LocalNow();
   datetime dayStart = local - (local % 86400);
   datetime st       = dayStart + gStartMin * 60;
   if(local < st)
      st -= 86400;
   return st - InpTimeOffsetHours * 3600;
  }

//+------------------------------------------------------------------+
//| Helpers: positions / history                                     |
//+------------------------------------------------------------------+
bool IsMine()
  {
   return (PositionGetString(POSITION_SYMBOL) == _Symbol &&
           PositionGetInteger(POSITION_MAGIC) == (long)InpMagic);
  }

int CountMyPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(IsMine())
         n++;
     }
   return n;
  }

int CountTradesSince(const datetime from)
  {
   if(!HistorySelect(from, TimeCurrent() + 86400))
      return 0;
   int n = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0)
         continue;
      if(HistoryDealGetInteger(tk, DEAL_MAGIC) != (long)InpMagic)
         continue;
      if(HistoryDealGetString(tk, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(tk, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;
      if(HistoryDealGetString(tk, DEAL_COMMENT) == CommentRunner())
         continue;   // 2-trade setup counts once
      n++;
     }
   return n;
  }

// Stop loss the position was opened with (from its opening order)
double InitialSL(const ulong posId, const double fallback)
  {
   if(HistorySelectByPosition(posId))
     {
      for(int i = 0; i < HistoryOrdersTotal(); i++)
        {
         ulong ot = HistoryOrderGetTicket(i);
         if(ot == 0)
            continue;
         double s = HistoryOrderGetDouble(ot, ORDER_SL);
         if(s > 0)
            return s;
        }
     }
   return fallback;
  }

bool PartialLegOpen()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !IsMine())
         continue;
      if(PositionGetString(POSITION_COMMENT) == CommentPartial())
         return true;
     }
   return false;
  }

void CloseAllPositions(const string reason)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !IsMine())
         continue;
      if(trade.PositionClose(tk, InpSlippagePoints))
         PrintFormat("Closed #%I64u - %s", tk, reason);
      else if(TimeCurrent() - gLastCloseFail >= 60)
        {
         gLastCloseFail = TimeCurrent();
         PrintFormat("Close #%I64u failed (%s): %u %s - will retry",
                     tk, reason, trade.ResultRetcode(), trade.ResultRetcodeDescription());
        }
     }
  }

//+------------------------------------------------------------------+
//| Helpers: market structure                                        |
//| Arrays are series-ordered: index 0 = forming bar, 1 = last closed |
//+------------------------------------------------------------------+
bool IsSwingHigh(const MqlRates &r[], const int n, const int i, const int s)
  {
   if(i - s < 1 || i + s >= n)
      return false;
   for(int k = 1; k <= s; k++)
     {
      if(r[i - k].high >= r[i].high) return false;
      if(r[i + k].high >  r[i].high) return false;
     }
   return true;
  }

bool IsSwingLow(const MqlRates &r[], const int n, const int i, const int s)
  {
   if(i - s < 1 || i + s >= n)
      return false;
   for(int k = 1; k <= s; k++)
     {
      if(r[i - k].low <= r[i].low) return false;
      if(r[i + k].low <  r[i].low) return false;
     }
   return true;
  }

// Is bar j the FIRST close beyond the most recent swing that was already
// confirmed before bar j?  dir = +1 bullish BOS, -1 bearish BOS.
bool IsBOS(const MqlRates &r[], const int n, const int j, const int dir, const int s)
  {
   for(int k = j + s + 1; k < n - s; k++)
     {
      bool isSwing = (dir < 0) ? IsSwingLow(r, n, k, s) : IsSwingHigh(r, n, k, s);
      if(!isSwing)
         continue;
      double level = (dir < 0) ? r[k].low : r[k].high;
      if(dir < 0)
        {
         if(r[j].close >= level) return false;
         for(int x = j + 1; x < k; x++)
            if(r[x].close < level) return false;  // already broken earlier
        }
      else
        {
         if(r[j].close <= level) return false;
         for(int x = j + 1; x < k; x++)
            if(r[x].close > level) return false;
        }
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| H4 trend                                                         |
//+------------------------------------------------------------------+
int EmaTrendH4()
  {
   double f[1], s[1];
   if(CopyBuffer(hFastEMA, 0, 1, 1, f) != 1 || CopyBuffer(hSlowEMA, 0, 1, 1, s) != 1)
      return 0;
   double c = iClose(_Symbol, PERIOD_H4, 1);
   if(c <= 0)
      return 0;
   if(f[0] > s[0] && c > s[0]) return  1;
   if(f[0] < s[0] && c < s[0]) return -1;
   return 0;
  }

int StructureTrendH4()
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int n = CopyRates(_Symbol, PERIOD_H4, 0, InpH4Lookback, r);
   if(n < 4 * InpH4SwingStrength + 10)
      return 0;
   for(int j = 1; j < n - 2 * InpH4SwingStrength - 1; j++)
     {
      if(IsBOS(r, n, j,  1, InpH4SwingStrength)) return  1;
      if(IsBOS(r, n, j, -1, InpH4SwingStrength)) return -1;
     }
   return 0;
  }

int GetH4Trend()
  {
   switch(InpTrendMode)
     {
      case TREND_EMA:       return EmaTrendH4();
      case TREND_STRUCTURE: return StructureTrendH4();
      default:
        {
         int e = EmaTrendH4();
         int s = StructureTrendH4();
         return (e == s) ? e : 0;
        }
     }
  }

string TrendText(const int t) { return t > 0 ? "BULLISH (buy only)" : (t < 0 ? "BEARISH (sell only)" : "NEUTRAL (no trade)"); }

//+------------------------------------------------------------------+
//| M30: last confirmed order block in direction dir                 |
//|  Bearish OB = last bullish candle before an impulsive drop that  |
//|  broke the previous M30 swing low (BOS). Bullish OB = mirror.    |
//|  The OB stays valid until an M30 candle CLOSES beyond its wick.  |
//+------------------------------------------------------------------+
bool FindLastOrderBlock(const int dir, OrderBlock &ob)
  {
   ob.found = false;
   int s    = InpM30SwingStrength;
   int need = InpOBLookbackBars + InpOBSearchBars + 4 * s + 60;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   int n = CopyRates(_Symbol, PERIOD_M30, 0, need, r);
   if(n < 4 * s + InpOBSearchBars + 10)
      return false;

   double atr[];
   ArraySetAsSeries(atr, true);
   int na = CopyBuffer(hATR, 0, 0, n, atr);
   if(na <= 0)
      return false;

   // j starts at 2: bar 1 is the signal candle, the BOS must be older than it
   for(int j = 2; j <= InpOBLookbackBars && j < n - 2 * s - 1 && j < na; j++)
     {
      if(!IsBOS(r, n, j, dir, s))
         continue;

      // OB candle = last opposite-colour candle before the impulse
      int m   = -1;
      int lim = MathMin(j + InpOBSearchBars, n - 1);
      for(int x = j + 1; x <= lim; x++)
        {
         bool opposite = (dir < 0) ? (r[x].close > r[x].open) : (r[x].close < r[x].open);
         if(opposite) { m = x; break; }
        }
      if(m < 0)
         continue;

      // displacement filter
      double ext = (dir < 0) ? r[j].low : r[j].high;
      for(int x = j; x < m; x++)
         ext = (dir < 0) ? MathMin(ext, r[x].low) : MathMax(ext, r[x].high);
      double impulse = (dir < 0) ? (r[m].high - ext) : (ext - r[m].low);
      if(atr[j] > 0 && impulse < InpMinImpulseATR * atr[j])
         continue;

      double wHi = r[m].high, wLo = r[m].low;
      double zHi = wHi,       zLo = wLo;
      if(InpOBZone == OB_ZONE_BODY)
        {
         zHi = MathMax(r[m].open, r[m].close);
         zLo = MathMin(r[m].open, r[m].close);
        }

      // validity after the BOS
      bool invalid = false, touched = false;
      for(int x = j - 1; x >= 1; x--)
        {
         if(dir < 0)
           {
            if(r[x].close > wHi) { invalid = true; break; }
            if(x >= 2 && r[x].high >= zLo) touched = true;
           }
         else
           {
            if(r[x].close < wLo) { invalid = true; break; }
            if(x >= 2 && r[x].low <= zHi) touched = true;
           }
        }
      if(invalid)
         continue;
      if(InpFreshOBOnly && touched)
         continue;

      ob.found   = true;
      ob.dir     = dir;
      ob.zoneHi  = zHi;
      ob.zoneLo  = zLo;
      ob.wickHi  = wHi;
      ob.wickLo  = wLo;
      ob.obTime  = r[m].time;
      ob.bosTime = r[j].time;
      return true;   // newest valid OB = the "last" order block
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Drawing / panel                                                  |
//+------------------------------------------------------------------+
void DrawOB()
  {
   if(!InpDrawOB)
      return;
   if(!gOB.found)
     {
      ObjectDelete(0, OB_OBJ_NAME);
      return;
     }
   datetime t2 = TimeCurrent() + PeriodSeconds(PERIOD_M30) * 6;
   if(ObjectFind(0, OB_OBJ_NAME) < 0)
      ObjectCreate(0, OB_OBJ_NAME, OBJ_RECTANGLE, 0, gOB.obTime, gOB.zoneHi, t2, gOB.zoneLo);
   else
     {
      ObjectMove(0, OB_OBJ_NAME, 0, gOB.obTime, gOB.zoneHi);
      ObjectMove(0, OB_OBJ_NAME, 1, t2, gOB.zoneLo);
     }
   ObjectSetInteger(0, OB_OBJ_NAME, OBJPROP_COLOR, gOB.dir < 0 ? clrTomato : clrDodgerBlue);
   ObjectSetInteger(0, OB_OBJ_NAME, OBJPROP_FILL, true);
   ObjectSetInteger(0, OB_OBJ_NAME, OBJPROP_BACK, true);
   ObjectSetInteger(0, OB_OBJ_NAME, OBJPROP_SELECTABLE, false);
   ObjectSetString(0, OB_OBJ_NAME, OBJPROP_TOOLTIP, gOB.dir < 0 ? "Bearish OB (sell zone)" : "Bullish OB (buy zone)");
  }

void UpdatePanel()
  {
   if(!InpShowPanel)
      return;
   string ob = "none";
   if(gOB.found)
      ob = StringFormat("%s %s - %s (BOS %s)", gOB.dir < 0 ? "SELL zone" : "BUY zone",
                        DoubleToString(gOB.zoneLo, _Digits), DoubleToString(gOB.zoneHi, _Digits),
                        TimeToString(gOB.bosTime, TIME_DATE | TIME_MINUTES));
   Comment(StringFormat(
              "XAUUSD H4 trend / M30 order block EA\n"
              "Session: %s -> %s (entries until %s)  now %s  [%s]\n"
              "H4 trend: %s\n"
              "Last confirmed OB: %s\n"
              "Open positions: %d   Trades this session: %d/%d\n"
              "Status: %s",
              MinToStr(gStartMin), MinToStr(gCloseMin), MinToStr(gEntryEndMin),
              MinToStr(MinutesOfDay(LocalNow())), InHoldWindow() ? "IN SESSION" : "OUT OF SESSION",
              TrendText(gTrend), ob,
              CountMyPositions(), InHoldWindow() ? CountTradesSince(SessionStartServer()) : 0,
              InpMaxTradesPerSession, gStatus));
  }

//+------------------------------------------------------------------+
//| Lot size                                                         |
//+------------------------------------------------------------------+
double CalcLots(const int dir, const double price, const double sl)
  {
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;
   int    vd   = (int)MathMax(0, MathCeil(-MathLog10(step) - 1e-9));
   ENUM_ORDER_TYPE type = (dir < 0) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

   double lots = InpFixedLot;
   if(InpLotMode == LOT_RISK_PERCENT)
     {
      double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
      double loss = 0.0;
      if(!OrderCalcProfit(type, _Symbol, 1.0, price, sl, loss) || loss == 0.0)
        {
         double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
         double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
         if(tv > 0 && ts > 0)
            loss = MathAbs(price - sl) / ts * tv;
        }
      loss = MathAbs(loss);
      if(loss <= 0)
         return 0.0;
      lots = riskMoney / loss;
      if(lots < vmin)
         PrintFormat("Risk %.2f%% gives %.4f lots < min lot %.2f - using min lot (risk is higher than set)",
                     InpRiskPercent, lots, vmin);
     }

   lots = MathFloor(lots / step + 1e-9) * step;
   lots = MathMax(vmin, MathMin(vmax, lots));

   // margin check
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double margin = 0.0;
   while(lots >= vmin)
     {
      if(OrderCalcMargin(type, _Symbol, lots, price, margin) && margin < freeMargin * 0.95)
         break;
      lots -= step;
     }
   if(lots < vmin)
      return 0.0;
   return NormalizeDouble(lots, vd);
  }

double RoundToTick(const double p)
  {
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0)
      return NormalizeDouble(p, _Digits);
   return NormalizeDouble(MathRound(p / ts) * ts, _Digits);
  }

//+------------------------------------------------------------------+
//| Entry                                                            |
//+------------------------------------------------------------------+
string EntryBlockReason()
  {
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return "Algo trading disabled";
   if(!InEntryWindow())
      return "Outside entry window";
   if(FridayNoEntry())
      return "Friday/weekend - no new trades";
   if(CountMyPositions() > 0)
      return "Position open - managing";
   if(CountTradesSince(SessionStartServer()) >= InpMaxTradesPerSession)
      return "Max trades for this session reached";
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPoints)
      return StringFormat("Spread too high (%d)", (int)spread);
   return "";
  }

bool SignalOnLastCandle()
  {
   MqlRates b[];
   ArraySetAsSeries(b, true);
   if(CopyRates(_Symbol, PERIOD_M30, 1, 1, b) != 1)
      return false;
   double mid = (gOB.zoneHi + gOB.zoneLo) / 2.0;

   if(gOB.dir < 0) // SELL: price retraced UP into the bearish OB
     {
      bool touch = (b[0].high >= gOB.zoneLo && b[0].close <= gOB.wickHi);
      if(!touch) return false;
      switch(InpConfirm)
        {
         case CONFIRM_TOUCH:         return true;
         case CONFIRM_REJECTION:     return (b[0].close < b[0].open && b[0].close < mid);
         case CONFIRM_CLOSE_OUTSIDE: return (b[0].close < b[0].open && b[0].close < gOB.zoneLo);
        }
     }
   else            // BUY: price retraced DOWN into the bullish OB
     {
      bool touch = (b[0].low <= gOB.zoneHi && b[0].close >= gOB.wickLo);
      if(!touch) return false;
      switch(InpConfirm)
        {
         case CONFIRM_TOUCH:         return true;
         case CONFIRM_REJECTION:     return (b[0].close > b[0].open && b[0].close > mid);
         case CONFIRM_CLOSE_OUTSIDE: return (b[0].close > b[0].open && b[0].close > gOB.zoneHi);
        }
     }
   return false;
  }

bool SendOrder(const int dir, const double lots, const double price, const double sl, const double tp, const string cmt)
  {
   bool ok = (dir < 0) ? trade.Sell(lots, _Symbol, price, sl, tp, cmt)
                       : trade.Buy(lots, _Symbol, price, sl, tp, cmt);
   if(ok && (trade.ResultRetcode() == TRADE_RETCODE_DONE || trade.ResultRetcode() == TRADE_RETCODE_PLACED))
     {
      PrintFormat("Opened %s %s %.2f lots SL %s TP %s", cmt, dir < 0 ? "SELL" : "BUY", lots,
                  DoubleToString(sl, _Digits), DoubleToString(tp, _Digits));
      return true;
     }
   PrintFormat("Order %s failed: %u %s", cmt, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   return false;
  }

void OpenTrade()
  {
   int    dir   = gOB.dir;
   double point = _Point;
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price = (dir < 0) ? bid : ask;

   double atrBuf = 0;
   if(InpSLBufferATR > 0)
     {
      double a[1];
      if(CopyBuffer(hATR, 0, 1, 1, a) == 1)
         atrBuf = InpSLBufferATR * a[0];
     }
   double buffer = InpSLBufferPoints * point + atrBuf;
   double sl = (dir < 0) ? gOB.wickHi + buffer + (ask - bid)
                         : gOB.wickLo - buffer;

   // price must still be on the right side of the OB
   if((dir < 0 && price >= sl) || (dir > 0 && price <= sl))
     {
      gStatus = "Price already beyond OB - skipped";
      return;
     }

   double dist     = MathAbs(price - sl);
   double minStops = (double)MathMax(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                                     SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)) * point;
   double minDist  = MathMax(InpMinSLPoints * point, minStops + 2 * point);
   if(dist < minDist)
     {
      dist = minDist;
      sl   = (dir < 0) ? price + dist : price - dist;
     }
   if(dist > InpMaxSLPoints * point)
     {
      gStatus = StringFormat("SL too wide (%.0f pts) - skipped", dist / point);
      gLastTradedOB = gOB.obTime;
      return;
     }

   double tp  = (dir < 0) ? price - InpRewardRisk * dist : price + InpRewardRisk * dist;
   double tp1 = (dir < 0) ? price - InpTP1RR * dist      : price + InpTP1RR * dist;
   sl  = RoundToTick(sl);
   tp  = RoundToTick(tp);
   tp1 = RoundToTick(tp1);

   double lots = CalcLots(dir, price, sl);
   if(lots <= 0)
     {
      gStatus = "Lot size 0 (not enough margin?) - skipped";
      return;
     }

   gLastTradedOB = gOB.obTime;   // never re-enter the same OB, even if an order fails

   if(!InpTwoTrades)
     {
      if(SendOrder(dir, lots, price, sl, tp, InpComment))
         gStatus = StringFormat("%s %.2f @ %s SL %s TP %s", dir < 0 ? "SELL" : "BUY", lots,
                                DoubleToString(price, _Digits), DoubleToString(sl, _Digits), DoubleToString(tp, _Digits));
      return;
     }

   // split total risk into partial leg + runner leg
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;
   int    vd   = (int)MathMax(0, MathCeil(-MathLog10(step) - 1e-9));
   double lot1 = MathFloor(lots * InpPartialLotPercent / 100.0 / step + 1e-9) * step;
   double lot2 = lots - lot1;
   if(lot1 < vmin || lot2 < vmin)
     {
      Print("Total lot too small to split - using min lot for each trade (risk is higher than set)");
      lot1 = MathMax(lot1, vmin);
      lot2 = MathMax(lot2, vmin);
     }
   lot1 = NormalizeDouble(lot1, vd);
   lot2 = NormalizeDouble(lot2, vd);

   bool ok1 = SendOrder(dir, lot1, price, sl, tp1, CommentPartial());
   double price2 = (dir < 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   bool ok2 = SendOrder(dir, lot2, price2, sl, tp, CommentRunner());
   gStatus = StringFormat("%s @ %s SL %s | T1 %.2f TP %s %s | T2 %.2f TP %s %s",
                          dir < 0 ? "SELL" : "BUY", DoubleToString(price, _Digits), DoubleToString(sl, _Digits),
                          lot1, DoubleToString(tp1, _Digits), ok1 ? "ok" : "FAILED",
                          lot2, DoubleToString(tp, _Digits), ok2 ? "ok" : "FAILED");
  }


void OnNewBar(const bool allowEntry)
  {
   gTrend = GetH4Trend();
   if(gTrend == 0)
     {
      gOB.found = false;
      DrawOB();
      gStatus = "H4 trend neutral - waiting";
      return;
     }

   if(!FindLastOrderBlock(gTrend, gOB))
     {
      DrawOB();
      gStatus = StringFormat("H4 %s - waiting for a confirmed M30 %s OB",
                             gTrend > 0 ? "bullish" : "bearish", gTrend > 0 ? "demand" : "supply");
      return;
     }
   DrawOB();

   if(!allowEntry)
     {
      gStatus = "Waiting for next M30 close";
      return;
     }

   string block = EntryBlockReason();
   if(block != "")
     {
      gStatus = block;
      return;
     }

   if(gOB.obTime == gLastTradedOB)
     {
      gStatus = "This OB was already traded - waiting for a new one";
      return;
     }

   if(!SignalOnLastCandle())
     {
      gStatus = StringFormat("Waiting for M30 retest of %s OB + confirmation", gOB.dir < 0 ? "SELL" : "BUY");
      return;
     }

   OpenTrade();
  }

//+------------------------------------------------------------------+
//| Position management: session close, breakeven, trailing          |
//+------------------------------------------------------------------+
void ManageSession()
  {
   if(CountMyPositions() == 0)
      return;
   if(!InHoldWindow())
      CloseAllPositions("session close " + MinToStr(gCloseMin));
   else if(FridayForceClose())
      CloseAllPositions("Friday/weekend close");
  }

void ManagePositions()
  {
   if(!InpTwoTrades && !InpUseBreakeven && !InpUseTrailing)
      return;

   double point = _Point;
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minStops = (double)MathMax(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                                     SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)) * point;
   double atr = 0;
   if(InpUseTrailing)
     {
      double a[1];
      if(CopyBuffer(hATR, 0, 1, 1, a) == 1)
         atr = a[0];
     }

   bool partialOpen = PartialLegOpen();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !IsMine())
         continue;

      long   type = PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      string cmt  = PositionGetString(POSITION_COMMENT);
      double R    = MathAbs(open - InitialSL((ulong)PositionGetInteger(POSITION_IDENTIFIER), sl)); // initial risk
      if(R <= 0)
         continue;

      bool   isBuy  = (type == POSITION_TYPE_BUY);
      double profit = isBuy ? (bid - open) : (open - ask);
      double newSL  = sl;
      bool   runner = (cmt == CommentRunner());

      // Trade 2 (runner): breakeven once trade 1's TP level is reached,
      // or once trade 1 is gone while price is in profit (it hit its TP)
      bool beNow = false;
      int  lock  = InpBreakevenLockPoints;
      if(runner)
        {
         beNow = (profit >= InpTP1RR * R) || (!partialOpen && profit > InpRunnerBELockPoints * point);
         lock  = InpRunnerBELockPoints;
        }
      else if(!InpTwoTrades && InpUseBreakeven)
         beNow = (profit >= InpBreakevenAtR * R);

      if(beNow)
        {
         double be = isBuy ? open + lock * point : open - lock * point;
         if(isBuy  && (sl == 0 || be > newSL)) newSL = be;
         if(!isBuy && (sl == 0 || be < newSL)) newSL = be;
        }

      if(InpUseTrailing && atr > 0 && profit >= InpTrailStartR * R && (runner || !InpTwoTrades))
        {
         double tr = isBuy ? bid - InpTrailATRMult * atr : ask + InpTrailATRMult * atr;
         if(isBuy  && tr > newSL) newSL = tr;
         if(!isBuy && tr < newSL) newSL = tr;
        }

      newSL = RoundToTick(newSL);
      if(MathAbs(newSL - sl) < point)
         continue;
      // respect broker stop level
      if(isBuy  && bid - newSL <= minStops) continue;
      if(!isBuy && newSL - ask <= minStops) continue;

      if(!trade.PositionModify(tk, newSL, tp))
         PrintFormat("Modify #%I64u failed: %u %s", tk, trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Events                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!ParseHHMM(InpSessionStart, gStartMin) || !ParseHHMM(InpSessionClose, gCloseMin) ||
      !ParseHHMM(InpFridayNoEntryTime, gFriNoEntryMin) || !ParseHHMM(InpFridayCloseTime, gFriCloseMin))
     {
      Print("Invalid time input. Use HH:MM, e.g. 13:00 or 04:30");
      return INIT_PARAMETERS_INCORRECT;
     }
   int windowLen = (gCloseMin - gStartMin + 1440) % 1440;
   if(windowLen == 0)
      windowLen = 1440;
   if(InpNoEntryMinutesBeforeClose < 0 || InpNoEntryMinutesBeforeClose >= windowLen)
     {
      Print("InpNoEntryMinutesBeforeClose must be >= 0 and shorter than the session window");
      return INIT_PARAMETERS_INCORRECT;
     }
   gEntryEndMin = (gCloseMin - InpNoEntryMinutesBeforeClose + 1440) % 1440;

   if(InpRewardRisk <= 0 || InpRiskPercent <= 0 || InpFixedLot <= 0 ||
      InpMinSLPoints <= 0 || InpMaxSLPoints <= InpMinSLPoints ||
      InpM30SwingStrength < 1 || InpH4SwingStrength < 1 || InpH4FastEMA >= InpH4SlowEMA ||
      InpMaxTradesPerSession < 1 || InpSLBufferATR < 0 ||
      (InpTwoTrades && (InpTP1RR <= 0 || InpTP1RR >= InpRewardRisk ||
                        InpPartialLotPercent <= 0 || InpPartialLotPercent >= 100)))
     {
      Print("Invalid risk/indicator inputs");
      return INIT_PARAMETERS_INCORRECT;
     }

   string sym = _Symbol;
   StringToUpper(sym);
   if(StringFind(sym, "XAU") < 0 && StringFind(sym, "GOLD") < 0)
      Print("WARNING: this EA is designed for XAUUSD / GOLD. Current symbol: ", _Symbol);

   hFastEMA = iMA(_Symbol, PERIOD_H4, InpH4FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlowEMA = iMA(_Symbol, PERIOD_H4, InpH4SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hATR     = iATR(_Symbol, PERIOD_M30, InpATRPeriod);
   if(hFastEMA == INVALID_HANDLE || hSlowEMA == INVALID_HANDLE || hATR == INVALID_HANDLE)
     {
      Print("Failed to create indicator handles");
      return INIT_FAILED;
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetMarginMode();

   gOB.found = false;
   // Do not enter on a candle that closed before the EA was attached
   gLastBarTime = iTime(_Symbol, PERIOD_M30, 0);
   OnNewBar(false);

   EventSetTimer(15);   // session close also runs without ticks
   UpdatePanel();
   PrintFormat("EA started. Session %s -> %s (entries until %s), clock = server %+d h",
               MinToStr(gStartMin), MinToStr(gCloseMin), MinToStr(gEntryEndMin), InpTimeOffsetHours);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(hFastEMA != INVALID_HANDLE) IndicatorRelease(hFastEMA);
   if(hSlowEMA != INVALID_HANDLE) IndicatorRelease(hSlowEMA);
   if(hATR     != INVALID_HANDLE) IndicatorRelease(hATR);
   ObjectDelete(0, OB_OBJ_NAME);
   Comment("");
  }

void OnTick()
  {
   ManageSession();
   if(CountMyPositions() > 0)
      ManagePositions();

   datetime bt = iTime(_Symbol, PERIOD_M30, 0);
   if(bt != 0 && bt != gLastBarTime)
     {
      gLastBarTime = bt;
      OnNewBar(true);
     }
   UpdatePanel();
  }

void OnTimer()
  {
   ManageSession();
   UpdatePanel();
  }
//+------------------------------------------------------------------+
