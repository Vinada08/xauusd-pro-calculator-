//+------------------------------------------------------------------+
//|                                  XAUUSD_Liquidity_Swing_EA.mq5   |
//|                                                                  |
//|  STRATEGY                                                        |
//|  1. D1 : liquidity of Friday (previous week), Monday and Tuesday.|
//|          Highest high of the 3 days -> SELL zone (buy-side liq). |
//|          Lowest  low  of the 3 days -> BUY  zone (sell-side liq).|
//|          The Tuesday D1 candle is mapped in YELLOW, its 50% /    |
//|          centre line is the partial take profit (TP1).           |
//|  2. H4 : order block inside a D1 zone                            |
//|          SELL zone -> bearish OB (last up candle before a        |
//|          bearish displacement), BUY zone -> bullish OB.          |
//|  3. M5 : the H4 OB is mapped on the M5 chart. Entry only after   |
//|          a rejection / wick candle at the OB (pin bar or         |
//|          engulfing).                                             |
//|  4. Each setup opens exactly 2 trades with the same stop loss:   |
//|          trade 1 -> TP1 = Tuesday 50% line  (partial)            |
//|          trade 2 -> TP2 = 1:2 risk reward   (full)               |
//|  5. New entries ONLY on Wednesday, Thursday, Friday.             |
//|     Trades are never closed early: they run until TP / SL or the |
//|     weekly close on Saturday 04:30 (if the market is already     |
//|     closed at that time the EA closes just before the Friday     |
//|     market close, which is the last possible moment).            |
//|  6. Telegram report bot: zones, order blocks, entries, TP / SL,  |
//|     weekly close, daily + weekly reports and /commands.          |
//+------------------------------------------------------------------+
#property copyright   "xauusd-pro-calculator"
#property link        "https://github.com/vinada08/xauusd-pro-calculator-"
#property version     "1.00"
#property description "XAUUSD swing EA: D1 Fri/Mon/Tue liquidity zones -> H4 order block -> M5 rejection entry."
#property description "Every setup = 2 trades: TP1 at the Tuesday D1 50% (yellow) + TP2 at 1:2 risk reward."
#property description "New entries Wed/Thu/Fri only. Weekly force-close Saturday 04:30. Telegram report bot."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_LOT_MODE
  {
   LOT_RISK_PERCENT = 0,   // Risk % of balance (split between the 2 trades)
   LOT_FIXED        = 1    // Fixed lot for each of the 2 trades
  };

enum ENUM_CLOSE_TZ
  {
   CLOSE_TZ_SERVER = 0,    // Broker server time (MT5 clock)
   CLOSE_TZ_LOCAL  = 1     // My local time (uses the GMT offset input)
  };

enum ENUM_ZONE_MODE
  {
   ZONE_PERCENT = 0,       // Top / bottom % of the Fri-Mon-Tue range
   ZONE_WICK    = 1        // Extreme wick to the highest / lowest candle body
  };

enum ENUM_SL_MODE
  {
   SL_OB_EXTREME = 0,      // Beyond the H4 order block (swing - recommended)
   SL_M5_CANDLE  = 1       // Beyond the M5 rejection candle (tighter)
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== General ==="
input long            InpMagic                = 260611;          // Magic number (TP1 trade = magic, TP2 trade = magic+1)
input string          InpComment              = "XAU LiqSwing";  // Order comment
input bool            InpOnlyGold             = true;            // Only run on gold symbols (XAU / GOLD)

input group "=== Trading days & weekly close ==="
input bool            InpTradeWednesday       = true;            // Allow new entries on Wednesday
input bool            InpTradeThursday        = true;            // Allow new entries on Thursday
input bool            InpTradeFriday          = true;            // Allow new entries on Friday
input int             InpEntryStartHour       = 1;               // Entry window start hour (server time)
input int             InpEntryEndHour         = 23;              // Entry window end hour (server time, exclusive)
input int             InpFridayLastEntryHour  = 18;              // Friday: no new entries from this hour (server time)
input bool            InpUseWeeklyClose       = true;            // Force-close all trades at the weekly close
input ENUM_CLOSE_TZ   InpCloseTimeZone        = CLOSE_TZ_SERVER; // Weekly close time is expressed in
input double          InpLocalGMTOffset       = 5.5;             // My local GMT offset in hours (for 'my local time')
input int             InpCloseHour            = 4;               // Weekly close hour (Saturday)
input int             InpCloseMinute          = 30;              // Weekly close minute (Saturday)
input int             InpCloseBeforeMarketMin = 15;              // If Saturday close is after market close: close N min before Friday close
input double          InpTesterBrokerGMT      = 2.0;             // Broker GMT offset used in Strategy Tester (live = auto)
input int             InpFallbackCloseHour    = 23;              // Fallback Friday market close hour (server) if unknown
input int             InpFallbackCloseMin     = 55;              // Fallback Friday market close minute (server)
input bool            InpCloseStale           = true;            // Close trades left over from a previous week

input group "=== D1 liquidity zones (Friday + Monday + Tuesday) ==="
input ENUM_ZONE_MODE  InpZoneMode             = ZONE_PERCENT;    // How to size the sell / buy zones
input double          InpZoneDepthPct         = 25.0;            // Zone depth: % of the 3-day range (percent mode)
input double          InpZoneMinDepthATR      = 0.25;            // Minimum zone depth (x D1 ATR)
input double          InpZoneSweepATR         = 0.35;            // Zone extends beyond the extreme for sweeps (x D1 ATR)
input bool            InpRequireSweep         = false;           // Require the Fri/Mon/Tue high/low to be swept first
input int             InpATRPeriod            = 14;              // ATR period (D1 / H4 / M5)

input group "=== H4 order blocks ==="
input int             InpOBLookback           = 60;              // H4 bars to scan for order blocks
input int             InpOBImpulseBars        = 3;               // Bars allowed for the displacement after the OB candle
input double          InpOBMinImpulseATR      = 1.0;             // Minimum displacement size (x H4 ATR)
input bool            InpOBRequireBOS         = true;            // Displacement must close beyond the OB candle
input int             InpMaxOBsPerSide        = 5;               // Max order blocks tracked per side

input group "=== M5 entry (rejection / wick candle) ==="
input bool            InpUsePinBar            = true;            // Pin bar / long-wick rejection candle
input double          InpPinMinWickPct        = 50.0;            // Rejection wick >= % of candle range
input double          InpPinMaxBodyPct        = 40.0;            // Candle body <= % of candle range
input bool            InpUseEngulfing         = true;            // Engulfing rejection candle
input double          InpMinCandleATR         = 0.30;            // Signal candle range >= x M5 ATR
input bool            InpRequireConfirm       = false;           // Wait for the next M5 candle to break the rejection candle

input group "=== Risk & targets ==="
input ENUM_LOT_MODE   InpLotMode              = LOT_RISK_PERCENT; // Lot sizing mode
input double          InpRiskPercent          = 1.0;             // Total risk per setup in % of balance (both trades)
input double          InpFixedLot             = 0.01;            // Fixed lot per trade (fixed mode)
input double          InpPartialLegPct        = 50.0;            // % of the setup volume on the TP1 (partial) trade
input double          InpMaxRiskPercent       = 3.0;             // Skip if min-lot rounding pushes risk above this %
input double          InpRewardRisk           = 2.0;             // Full TP (TP2) risk:reward
input double          InpMinPartialRR         = 0.5;             // Tuesday 50% must be at least this R away from entry
input double          InpFallbackPartialRR    = 1.0;             // TP1 at this R when the Tuesday 50% is not usable
input ENUM_SL_MODE    InpSLMode               = SL_OB_EXTREME;   // Stop loss placement
input double          InpSLBuffer             = 0.50;            // SL buffer beyond the OB / candle extreme (price, $)
input double          InpMinSL                = 3.00;            // Minimum SL distance (price, $)
input double          InpMaxSL                = 40.00;           // Maximum SL distance (price, $) - signal skipped above
input bool            InpMoveRunnerToBE       = true;            // Move the TP2 trade to breakeven when TP1 is hit
input double          InpBEOffset             = 0.30;            // Breakeven offset in profit (price, $)
input double          InpMaxSpread            = 0.80;            // Maximum spread allowed for entries (price, $)
input int             InpSlippagePoints       = 30;              // Maximum slippage (points)
input int             InpMaxSetupsPerWeek     = 1;               // Setups per week (each setup = 2 trades)

input group "=== Chart drawing ==="
input bool            InpDraw                 = true;            // Draw zones / Tuesday / order blocks
input bool            InpShowPanel            = true;            // Show the info panel
input color           InpSellZoneColor        = C'90,24,32';     // Sell zone fill
input color           InpBuyZoneColor         = C'18,70,42';     // Buy zone fill
input color           InpLiqHighColor         = clrTomato;       // Liquidity high lines
input color           InpLiqLowColor          = clrLimeGreen;    // Liquidity low lines
input color           InpTuesdayColor         = clrYellow;       // Tuesday candle + 50% partial TP line
input color           InpBearOBColor          = C'150,60,20';    // H4 bearish order block
input color           InpBullOBColor          = C'25,85,150';    // H4 bullish order block

input group "=== Telegram report bot ==="
input bool            InpTelegramEnable       = false;           // Enable Telegram reports
input string          InpTelegramToken        = "";              // Bot token from @BotFather
input string          InpTelegramChatId       = "";              // Chat id (user, group or channel)
input bool            InpTgScreenshot         = true;            // Attach chart screenshots (zones / entries)
input bool            InpTgCommands           = true;            // Answer /status /zones /report /chart /help
input int             InpTgPollSeconds        = 10;              // Command polling interval (seconds)
input bool            InpTgNotifyOB           = true;            // Message when a new H4 order block is mapped
input bool            InpTgDailyReport        = true;            // Send a daily report (Mon-Fri)
input int             InpTgDailyHour          = 23;              // Daily report hour (server time)
input int             InpTgDailyMinute        = 0;               // Daily report minute (server time)

//+------------------------------------------------------------------+
//| Data structures                                                  |
//+------------------------------------------------------------------+
struct SWeekLiquidity
  {
   bool              valid;
   datetime          weekStart;      // Monday 00:00 (server)
   bool              hasFri;
   bool              hasMon;
   bool              hasTue;
   datetime          friTime;
   datetime          monTime;
   datetime          tueTime;
   double            friHigh;
   double            friLow;
   double            monHigh;
   double            monLow;
   double            tueHigh;
   double            tueLow;
   double            liqHigh;
   double            liqLow;
   int               liqHighDow;
   int               liqLowDow;
   double            sellTop;
   double            sellBottom;
   double            buyTop;
   double            buyBottom;
   double            tueMid;         // Tuesday 50% = TP1 (partial)
   double            atrD1;
  };

struct SOrderBlock
  {
   datetime          time;           // H4 OB candle open time
   double            high;
   double            low;
   int               dir;            // -1 bearish OB (sell), +1 bullish OB (buy)
   bool              valid;          // false once price closed through it
   bool              used;           // a setup was already taken from it
  };

struct SStats
  {
   int               setups;
   int               closed;
   int               wins;
   int               losses;
   double            net;
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
const string   g_pfx     = "LSW_";
const string   g_eaName  = "XAU Liquidity Swing EA";
const string   g_eaVer   = "1.00";

CTrade         g_tradeP;                 // TP1 / partial trade (magic)
CTrade         g_tradeR;                 // TP2 / full trade (magic + 1)
SWeekLiquidity g_week;
SOrderBlock    g_obs[];

long           g_magicP            = 0;
long           g_magicR            = 0;
int            g_hAtrD1            = INVALID_HANDLE;
int            g_hAtrH4            = INVALID_HANDLE;
int            g_hAtrM5            = INVALID_HANDLE;
datetime       g_curWeekStart      = 0;
datetime       g_lastH4Bar         = 0;
datetime       g_lastM5Bar         = 0;
datetime       g_closeTarget       = 0;  // requested weekly close (Saturday 04:30) in server time
datetime       g_closeEffective    = 0;  // real close time (never after the Friday market close)
datetime       g_lastCloseAttempt  = 0;
datetime       g_lastTgPoll        = 0;
datetime       g_lastPanelUpdate   = 0;
bool           g_isTester          = false;
bool           g_visual            = true;
bool           g_drawOn            = true;
bool           g_netting           = false;
bool           g_tgUrlWarned       = false;
bool           g_closeFailNotified = false;
int            g_setupsMem         = 0;
long           g_tgOffset          = 0;
string         g_tgToken           = "";
string         g_tgChat            = "";
string         g_status            = "Initialising";
string         g_lastCloseReason   = "";

//+------------------------------------------------------------------+
//| Generic helpers                                                  |
//+------------------------------------------------------------------+
string Emo(const uint cp)
  {
   if(cp < 0x10000)
      return ShortToString((ushort)cp);
   uint v = cp - 0x10000;
   return ShortToString((ushort)(0xD800 + (v >> 10))) + ShortToString((ushort)(0xDC00 + (v & 0x3FF)));
  }

string E_Bot(void)    { return Emo(0x1F916); }
string E_Up(void)     { return Emo(0x1F4C8); }
string E_Down(void)   { return Emo(0x1F4C9); }
string E_Chart(void)  { return Emo(0x1F4CA); }
string E_Red(void)    { return Emo(0x1F534); }
string E_Green(void)  { return Emo(0x1F7E2); }
string E_Yellow(void) { return Emo(0x1F7E1); }
string E_Ok(void)     { return Emo(0x2705); }
string E_X(void)      { return Emo(0x274C); }
string E_Warn(void)   { return Emo(0x26A0); }
string E_Target(void) { return Emo(0x1F3AF); }
string E_Stop(void)   { return Emo(0x1F6D1); }
string E_Clock(void)  { return Emo(0x23F0); }
string E_Cal(void)    { return Emo(0x1F4C5); }
string E_Shield(void) { return Emo(0x1F6E1); }
string E_Box(void)    { return Emo(0x1F4E6); }

string P2S(const double price)       { return DoubleToString(price, _Digits); }
string M2S(const double money)       { return DoubleToString(money, 2); }
string Currency(void)                { return AccountInfoString(ACCOUNT_CURRENCY); }
string DirText(const bool isSell)    { return isSell ? "SELL" : "BUY"; }

string SignedMoney(const double v)
  {
   string s = DoubleToString(v, 2);
   if(v >= 0)
      s = "+" + s;
   return s;
  }

int VolumeDigits(void)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0)
      return 2;
   int d = 0;
   while(d < 8 && MathAbs(step - MathRound(step)) > 1e-9)
     {
      step *= 10.0;
      d++;
     }
   return d;
  }

string L2S(const double lots) { return DoubleToString(lots, VolumeDigits()); }

double NormPrice(const double price)
  {
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0)
      ts = _Point;
   return NormalizeDouble(MathRound(price / ts) * ts, _Digits);
  }

double FloorLot(const double lots)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0)
      step = 0.01;
   double v = MathFloor(lots / step + 1e-7) * step;
   if(vmax > 0 && v > vmax)
      v = vmax;
   return NormalizeDouble(v, VolumeDigits());
  }

int DowOf(const datetime t)
  {
   MqlDateTime d;
   TimeToStruct(t, d);
   return d.day_of_week;
  }

int MinuteOfDay(const datetime t)
  {
   MqlDateTime d;
   TimeToStruct(t, d);
   return d.hour * 60 + d.min;
  }

int HourOfDay(const datetime t)
  {
   MqlDateTime d;
   TimeToStruct(t, d);
   return d.hour;
  }

datetime DayStart(const datetime t)
  {
   return (datetime)((long)t - ((long)t % 86400));
  }

datetime WeekStartOf(const datetime t)
  {
   int back = (DowOf(t) + 6) % 7;            // Monday = 0 ... Sunday = 6
   return (datetime)((long)DayStart(t) - (long)back * 86400);
  }

string DayName(const int dow)
  {
   switch(dow)
     {
      case 0:
         return "Sun";
      case 1:
         return "Mon";
      case 2:
         return "Tue";
      case 3:
         return "Wed";
      case 4:
         return "Thu";
      case 5:
         return "Fri";
      case 6:
         return "Sat";
     }
   return "?";
  }

string DayTime(const datetime t)
  {
   if(t <= 0)
      return "n/a";
   return DayName(DowOf(t)) + " " + TimeToString(t, TIME_DATE | TIME_MINUTES);
  }

datetime ServerNow(void)
  {
   return g_isTester ? TimeCurrent() : TimeTradeServer();
  }

string GVName(const string key)
  {
   return "LSW_" + _Symbol + "_" + IntegerToString(InpMagic) + "_" + key;
  }

double GetATR(const int handle, const int shift)
  {
   if(handle == INVALID_HANDLE)
      return 0.0;
   double b[];
   if(CopyBuffer(handle, 0, shift, 1, b) != 1)
      return 0.0;
   if(b[0] == EMPTY_VALUE)
      return 0.0;
   return b[0];
  }

bool Overlaps(const double aLo, const double aHi, const double bLo, const double bHi)
  {
   return (aHi >= bLo && aLo <= bHi);
  }

double StopsDistance(void)
  {
   long lvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long frz = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   long m   = (lvl > frz) ? lvl : frz;
   return (double)m * _Point;
  }

void PushLine(string &arr[], const string s)
  {
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n] = s;
  }

//+------------------------------------------------------------------+
//| Weekly close time                                                |
//+------------------------------------------------------------------+
int BrokerGMTOffsetSec(void)
  {
   if(g_isTester)
      return (int)MathRound(InpTesterBrokerGMT * 3600.0);
   long diff = (long)TimeTradeServer() - (long)TimeGMT();
   return (int)(MathRound((double)diff / 900.0) * 900.0);
  }

datetime FridayMarketClose(const datetime weekStart)
  {
   datetime from = 0, to = 0;
   long latest = -1;
   for(uint i = 0; i < 10; i++)
     {
      if(!SymbolInfoSessionTrade(_Symbol, FRIDAY, i, from, to))
         break;
      if((long)to > latest)
         latest = (long)to;
     }
   if(latest < 12 * 3600)        // unknown / nonsense session -> fallback
      latest = (long)InpFallbackCloseHour * 3600 + (long)InpFallbackCloseMin * 60;
   return (datetime)((long)weekStart + 4 * 86400 + latest);
  }

void ComputeCloseTimes(const datetime weekStart)
  {
   long target = (long)weekStart + 5 * 86400 + (long)InpCloseHour * 3600 + (long)InpCloseMinute * 60;
   if(InpCloseTimeZone == CLOSE_TZ_LOCAL)
      target += (long)BrokerGMTOffsetSec() - (long)MathRound(InpLocalGMTOffset * 3600.0);
   g_closeTarget = (datetime)target;
   datetime mkt = (datetime)((long)FridayMarketClose(weekStart) - (long)InpCloseBeforeMarketMin * 60);
   g_closeEffective = (g_closeTarget < mkt) ? g_closeTarget : mkt;
  }

void EnsureWeek(const datetime now)
  {
   datetime ws = WeekStartOf(now);
   if(ws <= g_curWeekStart)
      return;
   g_curWeekStart      = ws;
   ZeroMemory(g_week);
   ArrayResize(g_obs, 0);
   g_setupsMem         = 0;
   g_lastH4Bar         = 0;
   g_closeFailNotified = false;
   ComputeCloseTimes(ws);
   g_status = "New week " + TimeToString(ws, TIME_DATE) + ": Fri/Mon/Tue liquidity forming";
  }

//+------------------------------------------------------------------+
//| Position / history helpers                                       |
//+------------------------------------------------------------------+
bool IsOurMagic(const long magic)
  {
   return (magic == g_magicP || magic == g_magicR);
  }

int CountOurPositions(int &nP, int &nR)
  {
   nP = 0;
   nR = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      long mg = PositionGetInteger(POSITION_MAGIC);
      if(mg == g_magicP)
         nP++;
      else
         if(mg == g_magicR)
            nR++;
     }
   return nP + nR;
  }

bool HasStalePosition(void)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(!IsOurMagic(PositionGetInteger(POSITION_MAGIC)))
         continue;
      if((datetime)PositionGetInteger(POSITION_TIME) < g_curWeekStart)
         return true;
     }
   return false;
  }

double FloatingPL(void)
  {
   double s = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(!IsOurMagic(PositionGetInteger(POSITION_MAGIC)))
         continue;
      s += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   return s;
  }

bool PositionOpenById(const long id)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(PositionGetInteger(POSITION_IDENTIFIER) == id)
         return true;
     }
   return false;
  }

string OpenPositionsText(void)
  {
   string s = "";
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      long mg = PositionGetInteger(POSITION_MAGIC);
      if(!IsOurMagic(mg))
         continue;
      bool isSell = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL);
      string leg = (mg == g_magicP) ? (g_netting ? "POS" : "TP1") : "TP2";
      s += " - " + leg + " " + DirText(isSell) + " " + L2S(PositionGetDouble(POSITION_VOLUME))
           + " @ " + P2S(PositionGetDouble(POSITION_PRICE_OPEN))
           + " | SL " + P2S(PositionGetDouble(POSITION_SL))
           + " | TP " + P2S(PositionGetDouble(POSITION_TP))
           + " | P/L " + SignedMoney(PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP)) + "\n";
     }
   if(s == "")
      s = " - none\n";
   return s;
  }

void CalcStats(const datetime from, const datetime to, SStats &s)
  {
   ZeroMemory(s);
   if(!HistorySelect(from, to))
      return;
   int cP = 0, cR = 0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol)
         continue;
      long mg = HistoryDealGetInteger(d, DEAL_MAGIC);
      if(!IsOurMagic(mg))
         continue;
      long entry   = HistoryDealGetInteger(d, DEAL_ENTRY);
      double costs = HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
      if(entry == DEAL_ENTRY_IN)
        {
         if(mg == g_magicP)
            cP++;
         else
            cR++;
         s.net += costs;
         continue;
        }
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
         continue;
      double pr = HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) + costs;
      s.closed++;
      s.net += pr;
      if(pr > 0)
         s.wins++;
      else
         if(pr < 0)
            s.losses++;
     }
   s.setups = (cP > cR) ? cP : cR;
  }

int SetupsThisWeek(void)
  {
   SStats s;
   CalcStats(g_curWeekStart, (datetime)((long)TimeCurrent() + 86400), s);
   return (s.setups > g_setupsMem) ? s.setups : g_setupsMem;
  }

//+------------------------------------------------------------------+
//| D1 liquidity: Friday (prev week) + Monday + Tuesday              |
//+------------------------------------------------------------------+
bool BuildWeeklyLiquidity(const datetime ws)
  {
   SWeekLiquidity w;
   ZeroMemory(w);
   w.weekStart = ws;

   MqlRates d1[];
   ArraySetAsSeries(d1, true);
   int n = CopyRates(_Symbol, PERIOD_D1, 0, 20, d1);
   if(n < 5)
     {
      g_status = "Loading D1 history...";
      return false;
     }

   datetime prevWs  = (datetime)((long)ws - 7 * 86400);
   datetime wed     = (datetime)((long)ws + 2 * 86400);
   double maxBodyTop = -DBL_MAX;
   double minBodyBot = DBL_MAX;
   w.liqHigh = -DBL_MAX;
   w.liqLow  = DBL_MAX;

   for(int i = 0; i < n; i++)
     {
      datetime t = d1[i].time;
      int dow = DowOf(t);
      if(dow == 0 || dow == 6)                       // ignore Sunday / Saturday stub candles
         continue;
      bool take = false;
      if(t >= ws && t < wed)
        {
         if(dow == 1 && !w.hasMon)
           {
            w.hasMon  = true;
            w.monTime = t;
            w.monHigh = d1[i].high;
            w.monLow  = d1[i].low;
            take = true;
           }
         else
            if(dow == 2 && !w.hasTue)
              {
               w.hasTue  = true;
               w.tueTime = t;
               w.tueHigh = d1[i].high;
               w.tueLow  = d1[i].low;
               take = true;
              }
        }
      else
         if(t >= prevWs && t < ws && !w.hasFri)
           {
            // newest candle of the previous week = Friday (Thursday if Friday was a holiday)
            w.hasFri  = true;
            w.friTime = t;
            w.friHigh = d1[i].high;
            w.friLow  = d1[i].low;
            take = true;
           }
      if(!take)
         continue;
      double bt = MathMax(d1[i].open, d1[i].close);
      double bb = MathMin(d1[i].open, d1[i].close);
      if(bt > maxBodyTop)
         maxBodyTop = bt;
      if(bb < minBodyBot)
         minBodyBot = bb;
      if(d1[i].high > w.liqHigh)
        {
         w.liqHigh    = d1[i].high;
         w.liqHighDow = dow;
        }
      if(d1[i].low < w.liqLow)
        {
         w.liqLow    = d1[i].low;
         w.liqLowDow = dow;
        }
     }

   int cnt = (w.hasFri ? 1 : 0) + (w.hasMon ? 1 : 0) + (w.hasTue ? 1 : 0);
   if(cnt < 2)
     {
      g_status = "Not enough D1 candles for Fri / Mon / Tue";
      return false;
     }
   double range = w.liqHigh - w.liqLow;
   if(range <= 0)
      return false;

   double atr = GetATR(g_hAtrD1, 1);
   if(atr <= 0)
      atr = range / 2.0;
   w.atrD1 = atr;

   double minDepth  = InpZoneMinDepthATR * atr;
   double ext       = InpZoneSweepATR * atr;
   double sellDepth = 0.0;
   double buyDepth  = 0.0;
   if(InpZoneMode == ZONE_PERCENT)
     {
      sellDepth = range * InpZoneDepthPct / 100.0;
      buyDepth  = sellDepth;
     }
   else
     {
      sellDepth = w.liqHigh - maxBodyTop;
      buyDepth  = minBodyBot - w.liqLow;
     }
   if(sellDepth < minDepth)
      sellDepth = minDepth;
   if(buyDepth < minDepth)
      buyDepth = minDepth;

   double mid   = (w.liqHigh + w.liqLow) / 2.0;
   w.sellTop    = w.liqHigh + ext;
   w.sellBottom = MathMax(w.liqHigh - sellDepth, mid);
   w.buyBottom  = w.liqLow - ext;
   w.buyTop     = MathMin(w.liqLow + buyDepth, mid);
   w.tueMid     = w.hasTue ? (w.tueHigh + w.tueLow) / 2.0 : 0.0;
   w.valid      = true;
   g_week = w;
   return true;
  }

//+------------------------------------------------------------------+
//| H4 order blocks inside the D1 zones                              |
//+------------------------------------------------------------------+
void PushOB(SOrderBlock &arr[], const datetime t, const double hi, const double lo, const int dir)
  {
   int s = ArraySize(arr);
   ArrayResize(arr, s + 1);
   arr[s].time  = t;
   arr[s].high  = hi;
   arr[s].low   = lo;
   arr[s].dir   = dir;
   arr[s].valid = true;
   arr[s].used  = false;
  }

int FindOB(const datetime t, const int dir)
  {
   for(int i = 0; i < ArraySize(g_obs); i++)
      if(g_obs[i].time == t && g_obs[i].dir == dir)
         return i;
   return -1;
  }

string OBLine(const SOrderBlock &ob)
  {
   string st   = !ob.valid ? "mitigated" : (ob.used ? "traded" : "active");
   string side = (ob.dir < 0) ? "SELL OB " : "BUY OB ";
   return side + TimeToString(ob.time, TIME_DATE | TIME_MINUTES) + "  " + P2S(ob.low) + " - " + P2S(ob.high) + " [" + st + "]";
  }

string OBListText(void)
  {
   int n = ArraySize(g_obs);
   if(n == 0)
      return "H4 order blocks in zones: none yet\n";
   string s = "H4 order blocks in zones:\n";
   for(int i = 0; i < n; i++)
      s += " - " + OBLine(g_obs[i]) + "\n";
   return s;
  }

void ScanOrderBlocks(const bool notify)
  {
   if(!g_week.valid)
      return;
   int need = InpOBLookback + 3;
   MqlRates h4[];
   ArraySetAsSeries(h4, true);
   int n = CopyRates(_Symbol, PERIOD_H4, 0, need, h4);
   if(n < InpOBImpulseBars + 3)
      return;

   double atr[];
   ArraySetAsSeries(atr, true);
   int na = CopyBuffer(g_hAtrH4, 0, 0, n, atr);
   double atrFb = GetATR(g_hAtrH4, 1);
   if(atrFb <= 0)
     {
      double sum = 0.0;
      int c = 0;
      for(int k = 1; k < n && k <= 20; k++)
        {
         sum += h4[k].high - h4[k].low;
         c++;
        }
      atrFb = (c > 0) ? sum / c : 0.0;
     }

   SOrderBlock found[];
   int nSell = 0, nBuy = 0;
   int maxI = (n - 1 < InpOBLookback) ? n - 1 : InpOBLookback;
   for(int i = 2; i <= maxI; i++)
     {
      double a = (na > i && atr[i] > 0 && atr[i] != EMPTY_VALUE) ? atr[i] : atrFb;
      if(a <= 0)
         continue;

      //--- bearish OB: last bullish candle before a bearish displacement (SELL zone)
      if(nSell < InpMaxOBsPerSide && h4[i].close > h4[i].open && h4[i - 1].close < h4[i - 1].open)
        {
         double minLow = DBL_MAX, minClose = DBL_MAX;
         for(int k = 1; k <= InpOBImpulseBars && i - k >= 1; k++)
           {
            if(h4[i - k].low < minLow)
               minLow = h4[i - k].low;
            if(h4[i - k].close < minClose)
               minClose = h4[i - k].close;
           }
         bool bos  = (!InpOBRequireBOS) || (minClose < h4[i].low);
         bool disp = (h4[i].high - minLow) >= InpOBMinImpulseATR * a;
         if(bos && disp && Overlaps(h4[i].low, h4[i].high, g_week.sellBottom, g_week.sellTop))
           {
            bool alive = true;
            for(int j = i - 1; j >= 1; j--)
               if(h4[j].close > h4[i].high)
                 {
                  alive = false;
                  break;
                 }
            if(alive)
              {
               PushOB(found, h4[i].time, h4[i].high, h4[i].low, -1);
               nSell++;
              }
           }
        }

      //--- bullish OB: last bearish candle before a bullish displacement (BUY zone)
      if(nBuy < InpMaxOBsPerSide && h4[i].close < h4[i].open && h4[i - 1].close > h4[i - 1].open)
        {
         double maxHigh = -DBL_MAX, maxClose = -DBL_MAX;
         for(int k = 1; k <= InpOBImpulseBars && i - k >= 1; k++)
           {
            if(h4[i - k].high > maxHigh)
               maxHigh = h4[i - k].high;
            if(h4[i - k].close > maxClose)
               maxClose = h4[i - k].close;
           }
         bool bos  = (!InpOBRequireBOS) || (maxClose > h4[i].high);
         bool disp = (maxHigh - h4[i].low) >= InpOBMinImpulseATR * a;
         if(bos && disp && Overlaps(h4[i].low, h4[i].high, g_week.buyBottom, g_week.buyTop))
           {
            bool alive = true;
            for(int j = i - 1; j >= 1; j--)
               if(h4[j].close < h4[i].low)
                 {
                  alive = false;
                  break;
                 }
            if(alive)
              {
               PushOB(found, h4[i].time, h4[i].high, h4[i].low, +1);
               nBuy++;
              }
           }
        }
     }

   //--- merge with the order blocks already known (keep used / invalid flags)
   int nf = ArraySize(found);
   int newCount = 0;
   string newText = "";
   for(int f = 0; f < nf; f++)
     {
      int old = FindOB(found[f].time, found[f].dir);
      if(old >= 0)
        {
         found[f].used = g_obs[old].used;
         if(!g_obs[old].valid)
            found[f].valid = false;
        }
      else
        {
         newCount++;
         newText += " - " + OBLine(found[f]) + "\n";
        }
     }
   //--- order blocks that disappeared were mitigated: grey them out
   for(int o = 0; o < ArraySize(g_obs); o++)
     {
      bool still = false;
      for(int f2 = 0; f2 < nf; f2++)
         if(found[f2].time == g_obs[o].time && found[f2].dir == g_obs[o].dir)
           {
            still = true;
            break;
           }
      if(!still && g_obs[o].valid)
        {
         g_obs[o].valid = false;
         DrawOB(g_obs[o]);
        }
     }
   ArrayResize(g_obs, nf);
   for(int f3 = 0; f3 < nf; f3++)
     {
      g_obs[f3] = found[f3];
      DrawOB(g_obs[f3]);
     }
   if(nf > 0)
      ChartRedraw(0);

   if(notify && newCount > 0 && InpTgNotifyOB)
     {
      string msg = E_Box() + " NEW H4 ORDER BLOCK mapped on M5 - " + _Symbol + "\n" + newText
                   + "Waiting for an M5 rejection / wick candle at the order block.";
      TgSend(msg);
     }
  }

//+------------------------------------------------------------------+
//| M5 rejection / wick candle                                       |
//+------------------------------------------------------------------+
bool IsRejection(const SOrderBlock &ob, const MqlRates &m5[], const int s, const double atr, string &pattern)
  {
   double hi = m5[s].high, lo = m5[s].low, op = m5[s].open, cl = m5[s].close;
   double range = hi - lo;
   if(range <= 0 || range < InpMinCandleATR * atr)
      return false;
   double body  = MathAbs(cl - op);
   double upper = hi - MathMax(op, cl);
   double lower = MathMin(op, cl) - lo;
   bool touch   = (hi >= ob.low && lo <= ob.high);

   double pHi = m5[s + 1].high, pLo = m5[s + 1].low, pOp = m5[s + 1].open, pCl = m5[s + 1].close;
   bool prevTouch = (pHi >= ob.low && pLo <= ob.high);

   if(ob.dir < 0)
     {
      if(cl >= ob.high)                      // closed above the OB -> no rejection
         return false;
      if(InpUsePinBar && touch && upper >= range * InpPinMinWickPct / 100.0 && body <= range * InpPinMaxBodyPct / 100.0)
        {
         pattern = "Bearish pin bar (upper wick rejection)";
         return true;
        }
      if(InpUseEngulfing && (touch || prevTouch) && pCl > pOp && cl < op && op >= pCl - _Point && cl < pOp && body >= range * 0.5)
        {
         pattern = "Bearish engulfing rejection";
         return true;
        }
     }
   else
     {
      if(cl <= ob.low)                       // closed below the OB -> no rejection
         return false;
      if(InpUsePinBar && touch && lower >= range * InpPinMinWickPct / 100.0 && body <= range * InpPinMaxBodyPct / 100.0)
        {
         pattern = "Bullish pin bar (lower wick rejection)";
         return true;
        }
      if(InpUseEngulfing && (touch || prevTouch) && pCl < pOp && cl > op && op <= pCl + _Point && cl > pOp && body >= range * 0.5)
        {
         pattern = "Bullish engulfing rejection";
         return true;
        }
     }
   return false;
  }

bool LiquiditySwept(const int dir)
  {
   datetime from = (datetime)((long)g_curWeekStart + 2 * 86400);    // Wednesday 00:00
   datetime to   = TimeCurrent();
   double arr[];
   if(dir < 0)
     {
      int n = CopyHigh(_Symbol, PERIOD_M5, from, to, arr);
      if(n <= 0)
         return false;
      return (arr[ArrayMaximum(arr)] > g_week.liqHigh);
     }
   int n2 = CopyLow(_Symbol, PERIOD_M5, from, to, arr);
   if(n2 <= 0)
      return false;
   return (arr[ArrayMinimum(arr)] < g_week.liqLow);
  }

bool CanOpenNewSetup(string &why)
  {
   datetime now = TimeCurrent();
   if(!g_week.valid)
     {
      why = "Waiting for D1 zones (built after the Tuesday close)";
      return false;
     }
   if(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) == 0 || MQLInfoInteger(MQL_TRADE_ALLOWED) == 0)
     {
      why = "Algo trading is disabled (AutoTrading button / EA settings)";
      return false;
     }
   if(AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) == 0 || AccountInfoInteger(ACCOUNT_TRADE_EXPERT) == 0)
     {
      why = "Trading not allowed on this account";
      return false;
     }
   int dow = DowOf(now);
   int hr  = HourOfDay(now);
   bool dayOk = (dow == 3 && InpTradeWednesday) || (dow == 4 && InpTradeThursday) || (dow == 5 && InpTradeFriday);
   if(!dayOk)
     {
      why = "No new entries on " + DayName(dow) + " (Wed / Thu / Fri only)";
      return false;
     }
   if(hr < InpEntryStartHour || hr >= InpEntryEndHour)
     {
      why = "Outside the entry hours";
      return false;
     }
   if(dow == 5 && hr >= InpFridayLastEntryHour)
     {
      why = "Friday entry cut-off reached";
      return false;
     }
   if(InpUseWeeklyClose && (long)now >= (long)g_closeEffective - 3600)
     {
      why = "Too close to the weekly close";
      return false;
     }
   int setups = SetupsThisWeek();
   if(setups >= InpMaxSetupsPerWeek)
     {
      why = "Weekly limit reached (" + IntegerToString(setups) + "/" + IntegerToString(InpMaxSetupsPerWeek) + " setups)";
      return false;
     }
   int nP = 0, nR = 0;
   if(CountOurPositions(nP, nR) > 0)
     {
      why = "Trade running - holding until TP / SL or weekly close";
      return false;
     }
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
     {
      why = "No price";
      return false;
     }
   if(tick.ask - tick.bid > InpMaxSpread)
     {
      why = "Spread too high (" + P2S(tick.ask - tick.bid) + ")";
      return false;
     }
   return true;
  }

void CheckEntries(void)
  {
   MqlRates m5[];
   ArraySetAsSeries(m5, true);
   if(CopyRates(_Symbol, PERIOD_M5, 0, 6, m5) < 6)
      return;

   //--- an M5 close through the order block invalidates it
   for(int i = 0; i < ArraySize(g_obs); i++)
     {
      if(!g_obs[i].valid)
         continue;
      if((g_obs[i].dir < 0 && m5[1].close > g_obs[i].high) || (g_obs[i].dir > 0 && m5[1].close < g_obs[i].low))
        {
         g_obs[i].valid = false;
         DrawOB(g_obs[i]);
        }
     }

   string why = "";
   if(!CanOpenNewSetup(why))
     {
      g_status = why;
      return;
     }

   double atrM5 = GetATR(g_hAtrM5, 1);
   if(atrM5 <= 0)
      atrM5 = m5[1].high - m5[1].low;
   int sig = InpRequireConfirm ? 2 : 1;

   int active = 0;
   for(int i = 0; i < ArraySize(g_obs); i++)
      if(g_obs[i].valid && !g_obs[i].used)
         active++;
   if(active == 0)
     {
      g_status = "Watching: no active H4 order block inside the D1 zones";
      return;
     }
   g_status = "Watching " + IntegerToString(active) + " H4 OB(s) for an M5 rejection candle";

   for(int i = 0; i < ArraySize(g_obs); i++)
     {
      if(!g_obs[i].valid || g_obs[i].used)
         continue;
      string pattern = "";
      if(!IsRejection(g_obs[i], m5, sig, atrM5, pattern))
         continue;
      if(InpRequireConfirm)
        {
         if(g_obs[i].dir < 0 && !(m5[1].close < m5[2].low))
            continue;
         if(g_obs[i].dir > 0 && !(m5[1].close > m5[2].high))
            continue;
         pattern += " + confirmation candle";
        }
      if(InpRequireSweep && !LiquiditySwept(g_obs[i].dir))
        {
         g_status = "Rejection seen but the Fri/Mon/Tue liquidity is not swept yet";
         continue;
        }
      if(OpenSetup(i, m5, sig, pattern))
        {
         g_obs[i].used = true;
         DrawOB(g_obs[i]);
         break;
        }
     }
  }

//+------------------------------------------------------------------+
//| Trading                                                          |
//+------------------------------------------------------------------+
void ConfigureTrade(CTrade &t, const long magic)
  {
   t.SetExpertMagicNumber((ulong)magic);
   t.SetDeviationInPoints((ulong)InpSlippagePoints);
   t.SetTypeFillingBySymbol(_Symbol);
   t.SetMarginMode();
   t.LogLevel(LOG_LEVEL_ERRORS);
  }

bool CalcLots(const bool isSell, const double entry, const double sl, double &lotP, double &lotR, double &riskMoney, string &err)
  {
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double bal  = AccountInfoDouble(ACCOUNT_BALANCE);
   ENUM_ORDER_TYPE type = isSell ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

   double lossPerLot = 0.0;
   double pr = 0.0;
   if(OrderCalcProfit(type, _Symbol, 1.0, entry, sl, pr) && pr < 0)
      lossPerLot = -pr;
   else
     {
      double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tv > 0 && ts > 0)
         lossPerLot = MathAbs(entry - sl) / ts * tv;
     }
   if(lossPerLot <= 0)
     {
      err = "cannot calculate the loss per lot";
      return false;
     }

   if(InpLotMode == LOT_FIXED)
     {
      lotP = FloorLot(InpFixedLot);
      lotR = lotP;
     }
   else
     {
      double total = (bal * InpRiskPercent / 100.0) / lossPerLot;
      lotP = FloorLot(total * InpPartialLegPct / 100.0);
      lotR = FloorLot(total * (100.0 - InpPartialLegPct) / 100.0);
     }
   if(lotP < vmin)
      lotP = vmin;
   if(lotR < vmin)
      lotR = vmin;

   riskMoney = (lotP + lotR) * lossPerLot;
   if(InpLotMode == LOT_RISK_PERCENT && bal > 0 && riskMoney > bal * InpMaxRiskPercent / 100.0)
     {
      err = "minimum lot risk " + M2S(riskMoney) + " " + Currency() + " is above the max "
            + DoubleToString(InpMaxRiskPercent, 1) + "% of balance";
      return false;
     }
   double margin = 0.0;
   if(OrderCalcMargin(type, _Symbol, lotP + lotR, entry, margin) && margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.95)
     {
      err = "not enough free margin (" + M2S(margin) + " needed)";
      return false;
     }
   return true;
  }

bool SendMarket(CTrade &t, const bool isSell, const double lots, const double sl, const double tp, const string comment, ulong &ticket)
  {
   ticket = 0;
   for(int attempt = 1; attempt <= 3; attempt++)
     {
      bool ok = isSell ? t.Sell(lots, _Symbol, 0.0, sl, tp, comment) : t.Buy(lots, _Symbol, 0.0, sl, tp, comment);
      int rc  = (int)t.ResultRetcode();
      if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED))
        {
         ticket = t.ResultOrder();
         return true;
        }
      Print(DirText(isSell), " ", L2S(lots), " failed (attempt ", attempt, "): ", rc, " ", t.ResultRetcodeDescription());
      if(rc != TRADE_RETCODE_REQUOTE && rc != TRADE_RETCODE_PRICE_CHANGED && rc != TRADE_RETCODE_PRICE_OFF &&
         rc != TRADE_RETCODE_TIMEOUT && rc != TRADE_RETCODE_CONNECTION && rc != TRADE_RETCODE_INVALID_STOPS)
         break;
      Sleep(400);
     }
   return false;
  }

bool OpenSetup(const int idx, const MqlRates &m5[], const int sig, const string pattern)
  {
   bool isSell = (g_obs[idx].dir < 0);
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;
   double spread = tick.ask - tick.bid;
   double entry  = isSell ? tick.bid : tick.ask;

   //--- stop loss: beyond the H4 OB (or the M5 rejection candle) + buffer
   double candleExt = isSell ? m5[sig].high : m5[sig].low;
   if(sig == 2)
      candleExt = isSell ? MathMax(candleExt, m5[1].high) : MathMin(candleExt, m5[1].low);
   double ext = candleExt;
   if(InpSLMode == SL_OB_EXTREME)
      ext = isSell ? MathMax(g_obs[idx].high, candleExt) : MathMin(g_obs[idx].low, candleExt);
   double sl      = isSell ? ext + InpSLBuffer + spread : ext - InpSLBuffer;
   double minDist = StopsDistance() + spread;
   double minSL   = MathMax(InpMinSL, minDist);
   double risk    = isSell ? sl - entry : entry - sl;
   if(risk < minSL)
     {
      sl   = isSell ? entry + minSL : entry - minSL;
      risk = minSL;
     }
   if(risk > InpMaxSL)
     {
      g_status = DirText(isSell) + " signal skipped: SL " + P2S(risk) + " > max " + P2S(InpMaxSL);
      Print(g_status);
      return false;
     }

   //--- targets: TP2 = 1:RR, TP1 = Tuesday 50% (partial)
   double fullDist = InpRewardRisk * risk;
   double tp2 = isSell ? entry - fullDist : entry + fullDist;
   double tp1 = 0.0;
   string tp1Src = "";
   if(g_week.hasTue && g_week.tueMid > 0)
     {
      double d = isSell ? entry - g_week.tueMid : g_week.tueMid - entry;
      if(d >= InpMinPartialRR * risk && d < fullDist && d >= minDist)
        {
         tp1    = g_week.tueMid;
         tp1Src = "Tuesday D1 50%";
        }
     }
   if(tp1 <= 0.0)
     {
      double r = MathMin(InpFallbackPartialRR, InpRewardRisk);
      tp1    = isSell ? entry - r * risk : entry + r * risk;
      tp1Src = DoubleToString(r, 1) + "R fallback - Tuesday 50% not between entry and TP2";
     }
   sl  = NormPrice(sl);
   tp1 = NormPrice(tp1);
   tp2 = NormPrice(tp2);

   //--- volume
   double lotP = 0.0, lotR = 0.0, riskMoney = 0.0;
   string err = "";
   if(!CalcLots(isSell, entry, sl, lotP, lotR, riskMoney, err))
     {
      g_status = DirText(isSell) + " signal skipped: " + err;
      Print(g_status);
      TgSend(E_Warn() + " " + _Symbol + " " + DirText(isSell) + " signal skipped: " + err);
      g_obs[idx].used = true;                // do not retry the same order block every bar
      DrawOB(g_obs[idx]);
      return false;
     }

   //--- send the 2 trades (hedging) or 1 trade + EA-managed partial (netting)
   ulong tP = 0, tR = 0;
   bool okP = false, okR = false;
   string warn = "";
   if(g_netting)
     {
      double total = FloorLot(lotP + lotR);
      okP = SendMarket(g_tradeP, isSell, total, sl, tp2, InpComment + " TP2", tP);
      if(okP)
        {
         GlobalVariableSet(GVName("vtp1"), tp1);
         GlobalVariableSet(GVName("vtp1vol"), lotP);
         GlobalVariableSet(GVName("vtp1done"), 0.0);
        }
     }
   else
     {
      okP = SendMarket(g_tradeP, isSell, lotP, sl, tp1, InpComment + " TP1", tP);
      okR = SendMarket(g_tradeR, isSell, lotR, sl, tp2, InpComment + " TP2", tR);
      if(okP != okR)
        {
         string which = okP ? "TP1 partial" : "TP2 full";
         warn = "\n" + E_Warn() + " Only the " + which + " trade could be opened.";
        }
     }
   if(!okP && !okR)
     {
      g_status = "Order failed: " + g_tradeP.ResultRetcodeDescription();
      TgSend(E_X() + " " + _Symbol + " " + DirText(isSell) + " entry FAILED: " + g_tradeP.ResultRetcodeDescription());
      return false;
     }
   g_setupsMem++;

   double fill = okP ? g_tradeP.ResultPrice() : g_tradeR.ResultPrice();
   if(fill <= 0)
      fill = entry;
   double rr1 = (risk > 0) ? MathAbs(tp1 - entry) / risk : 0.0;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskPct = (bal > 0) ? riskMoney / bal * 100.0 : 0.0;

   DrawSignal(isSell, m5[sig].time, isSell ? m5[sig].high : m5[sig].low);

   string legs = "";
   if(g_netting)
      legs = E_Yellow() + " TP1 partial: " + P2S(tp1) + " (" + tp1Src + ", " + DoubleToString(rr1, 2) + "R) - EA closes " + L2S(lotP) + " lot\n"
             + E_Target() + " TP2 full: " + P2S(tp2) + " (1:" + DoubleToString(InpRewardRisk, 1) + ") - total " + L2S(FloorLot(lotP + lotR)) + " lot\n";
   else
      legs = E_Yellow() + " Trade 1 TP1 partial: " + P2S(tp1) + " (" + tp1Src + ", " + DoubleToString(rr1, 2) + "R) | " + L2S(lotP) + " lot\n"
             + E_Target() + " Trade 2 TP2 full: " + P2S(tp2) + " (1:" + DoubleToString(InpRewardRisk, 1) + ") | " + L2S(lotR) + " lot\n";

   string msg = (isSell ? E_Down() : E_Up()) + " " + DirText(isSell) + " SETUP OPENED - " + _Symbol + "\n"
                + "Signal: M5 " + pattern + "\n"
                + "H4 OB: " + P2S(g_obs[idx].low) + " - " + P2S(g_obs[idx].high) + " in the D1 " + DirText(isSell) + " zone\n"
                + "Entry: " + P2S(fill) + "\n"
                + E_Stop() + " SL: " + P2S(sl) + " (" + P2S(risk) + " away)\n"
                + legs
                + "Risk: " + M2S(riskMoney) + " " + Currency() + " (" + DoubleToString(riskPct, 2) + "%)\n"
                + E_Clock() + " Held until TP / SL or the weekly close " + DayTime(g_closeEffective) + " (server)"
                + warn;
   Print(DirText(isSell), " setup opened: entry ", P2S(fill), " SL ", P2S(sl), " TP1 ", P2S(tp1), " TP2 ", P2S(tp2));
   TgSend(msg);
   TgSendScreenshot(_Symbol + " " + DirText(isSell) + " entry @ " + P2S(fill) + " | SL " + P2S(sl) + " | TP1 " + P2S(tp1) + " | TP2 " + P2S(tp2));
   g_status = DirText(isSell) + " setup running - holding until TP / SL or weekly close";
   return true;
  }

//+------------------------------------------------------------------+
//| Trade management                                                 |
//+------------------------------------------------------------------+
bool MoveToBreakeven(CTrade &t, const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return false;
   bool isSell = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL);
   double open = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl   = PositionGetDouble(POSITION_SL);
   double tp   = PositionGetDouble(POSITION_TP);
   double be   = NormPrice(isSell ? open - InpBEOffset : open + InpBEOffset);
   if(isSell && sl > 0 && sl <= be + _Point * 0.5)
      return true;                           // already at / beyond breakeven
   if(!isSell && sl > 0 && sl >= be - _Point * 0.5)
      return true;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;
   double minDist = StopsDistance();
   if(isSell && be <= tick.ask + minDist)
      return false;                          // price is not far enough yet - retry later
   if(!isSell && be >= tick.bid - minDist)
      return false;
   if(!t.PositionModify(ticket, be, tp))
     {
      Print("Breakeven modify failed #", ticket, ": ", t.ResultRetcodeDescription());
      return false;
     }
   TgSend(E_Shield() + " " + _Symbol + " TP1 done - TP2 trade moved to breakeven: SL " + P2S(be) + " | TP2 " + P2S(tp));
   return true;
  }

bool PartialTPHitSince(const datetime opened)
  {
   if(!HistorySelect((datetime)((long)opened - 60), (datetime)((long)TimeCurrent() + 3600)))
      return false;
   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != g_magicP)
         continue;
      long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
         continue;
      if((datetime)HistoryDealGetInteger(d, DEAL_TIME) < opened)
         continue;
      long reason = HistoryDealGetInteger(d, DEAL_REASON);
      if(reason == DEAL_REASON_TP || HistoryDealGetDouble(d, DEAL_PROFIT) > 0)
         return true;
     }
   return false;
  }

void ManageBreakeven(void)
  {
   if(!InpMoveRunnerToBE || g_netting)
      return;
   int nP = 0, nR = 0;
   CountOurPositions(nP, nR);
   if(nR == 0 || nP > 0)
      return;                                // TP1 trade still open (or no runner)
   ulong tickets[];
   long  times[];
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != g_magicR)
         continue;
      int n = ArraySize(tickets);
      ArrayResize(tickets, n + 1);
      ArrayResize(times, n + 1);
      tickets[n] = tk;
      times[n]   = PositionGetInteger(POSITION_TIME);
     }
   for(int j = 0; j < ArraySize(tickets); j++)
      if(PartialTPHitSince((datetime)times[j]))
         MoveToBreakeven(g_tradeR, tickets[j]);
  }

//--- netting accounts: one position, TP1 handled by the EA (partial close)
void ManageVirtualPartial(void)
  {
   if(!g_netting)
      return;
   string gTp = GVName("vtp1"), gVol = GVName("vtp1vol"), gDone = GVName("vtp1done");
   if(!GlobalVariableCheck(gTp))
      return;
   ulong ticket = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == g_magicP)
        {
         ticket = tk;
         break;
        }
     }
   if(ticket == 0)
     {
      GlobalVariableDel(gTp);
      GlobalVariableDel(gVol);
      GlobalVariableDel(gDone);
      return;
     }
   if(GlobalVariableCheck(gDone) && GlobalVariableGet(gDone) > 0.5)
      return;
   if(!PositionSelectByTicket(ticket))
      return;
   bool isSell   = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL);
   double posVol = PositionGetDouble(POSITION_VOLUME);
   double tp1    = GlobalVariableGet(gTp);
   double vol    = FloorLot(GlobalVariableGet(gVol));
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;
   bool hit = isSell ? (tick.ask <= tp1) : (tick.bid >= tp1);
   if(!hit)
      return;
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(vol < vmin || vol >= posVol)
     {
      GlobalVariableSet(gDone, 1.0);
      return;
     }
   // netting: one position per symbol -> use the symbol overload (the ticket overload is hedging-only in CTrade)
   if(g_tradeP.PositionClosePartial(_Symbol, vol))
     {
      GlobalVariableSet(gDone, 1.0);
      if(InpMoveRunnerToBE)
         MoveToBreakeven(g_tradeP, ticket);
     }
  }

void CloseAllOurPositions(const string reason)
  {
   g_lastCloseReason = reason;
   int fails = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      long mg = PositionGetInteger(POSITION_MAGIC);
      if(!IsOurMagic(mg))
         continue;
      bool ok = false;
      if(g_netting)
         ok = g_tradeP.PositionClose(_Symbol);
      else
         ok = (mg == g_magicR) ? g_tradeR.PositionClose(tk) : g_tradeP.PositionClose(tk);
      int rc  = (mg == g_magicR) ? (int)g_tradeR.ResultRetcode() : (int)g_tradeP.ResultRetcode();
      if(!ok || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_DONE_PARTIAL && rc != TRADE_RETCODE_PLACED))
        {
         fails++;
         Print("Close failed #", tk, " retcode ", rc);
        }
     }
   if(fails > 0 && !g_closeFailNotified)
     {
      g_closeFailNotified = true;
      TgSend(E_Warn() + " " + _Symbol + " " + reason + ": " + IntegerToString(fails)
             + " trade(s) could not be closed (market closed?). The EA keeps retrying.");
     }
  }

void CheckWeeklyClose(const datetime now)
  {
   if(!InpUseWeeklyClose || g_curWeekStart == 0)
      return;
   int nP = 0, nR = 0;
   if(CountOurPositions(nP, nR) == 0)
      return;
   bool due   = (g_closeEffective > 0 && now >= g_closeEffective);
   bool stale = InpCloseStale && HasStalePosition();
   if(!due && !stale)
      return;
   long since = (long)now - (long)g_lastCloseAttempt;
   if(g_lastCloseAttempt > 0 && since >= 0 && since < 15)
      return;
   g_lastCloseAttempt = now;
   string tz = (InpCloseTimeZone == CLOSE_TZ_LOCAL) ? "local" : "server";
   string reason = "";
   if(due)
      reason = "WEEKLY CLOSE (Saturday " + StringFormat("%02d:%02d", InpCloseHour, InpCloseMinute) + " " + tz + " rule)";
   else
      reason = "Trade left over from the previous week closed";
   CloseAllOurPositions(reason);
  }

//+------------------------------------------------------------------+
//| Chart drawing                                                    |
//+------------------------------------------------------------------+
void DrawRect(const string name, const datetime t1, const double p1, const datetime t2, const double p2,
              const color clr, const bool fill, const int width, const ENUM_LINE_STYLE style, const bool back)
  {
   if(!g_drawOn)
      return;
   if(ObjectFind(0, name) < 0)
     {
      if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2))
         return;
     }
   else
     {
      ObjectMove(0, name, 0, t1, p1);
      ObjectMove(0, name, 1, t2, p2);
     }
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL, fill);
   ObjectSetInteger(0, name, OBJPROP_BACK, back);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void DrawSeg(const string name, const datetime t1, const double p1, const datetime t2, const double p2,
             const color clr, const int width, const ENUM_LINE_STYLE style)
  {
   if(!g_drawOn)
      return;
   if(ObjectFind(0, name) < 0)
     {
      if(!ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2))
         return;
     }
   else
     {
      ObjectMove(0, name, 0, t1, p1);
      ObjectMove(0, name, 1, t2, p2);
     }
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void DrawLabel(const string name, const datetime t, const double price, const string text, const color clr, const ENUM_ANCHOR_POINT anchor)
  {
   if(!g_drawOn)
      return;
   if(ObjectFind(0, name) < 0)
     {
      if(!ObjectCreate(0, name, OBJ_TEXT, 0, t, price))
         return;
     }
   else
      ObjectMove(0, name, 0, t, price);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void DrawDayLevels(const string name, const datetime t, const double hi, const double lo, const datetime tEnd)
  {
   string dn = DayName(DowOf(t));
   DrawSeg(name + "_H", t, hi, tEnd, hi, InpLiqHighColor, 1, STYLE_DOT);
   DrawSeg(name + "_L", t, lo, tEnd, lo, InpLiqLowColor, 1, STYLE_DOT);
   DrawLabel(name + "_HT", t, hi, dn + " H " + P2S(hi), InpLiqHighColor, ANCHOR_LEFT_LOWER);
   DrawLabel(name + "_LT", t, lo, dn + " L " + P2S(lo), InpLiqLowColor, ANCHOR_LEFT_UPPER);
  }

void DrawWeek(void)
  {
   if(!g_drawOn || !g_week.valid)
      return;
   string p      = g_pfx + TimeToString(g_week.weekStart, TIME_DATE) + "_";
   datetime tEnd = (datetime)((long)g_week.weekStart + 5 * 86400);       // Saturday 00:00
   datetime tWed = (datetime)((long)g_week.weekStart + 2 * 86400);
   datetime tStart = g_week.hasFri ? g_week.friTime : (g_week.hasMon ? g_week.monTime : g_week.tueTime);

   //--- sell / buy zones
   DrawRect(p + "SELLZONE", tStart, g_week.sellTop, tEnd, g_week.sellBottom, InpSellZoneColor, true, 1, STYLE_SOLID, true);
   DrawRect(p + "BUYZONE", tStart, g_week.buyTop, tEnd, g_week.buyBottom, InpBuyZoneColor, true, 1, STYLE_SOLID, true);
   DrawLabel(p + "SELLZONE_T", tWed, g_week.sellTop, "SELL ZONE (D1 liquidity high)  " + P2S(g_week.sellBottom) + " - " + P2S(g_week.sellTop),
             InpLiqHighColor, ANCHOR_LEFT_LOWER);
   DrawLabel(p + "BUYZONE_T", tWed, g_week.buyBottom, "BUY ZONE (D1 liquidity low)  " + P2S(g_week.buyBottom) + " - " + P2S(g_week.buyTop),
             InpLiqLowColor, ANCHOR_LEFT_UPPER);

   //--- Friday / Monday / Tuesday highs and lows
   if(g_week.hasFri)
      DrawDayLevels(p + "FRI", g_week.friTime, g_week.friHigh, g_week.friLow, tEnd);
   if(g_week.hasMon)
      DrawDayLevels(p + "MON", g_week.monTime, g_week.monHigh, g_week.monLow, tEnd);
   if(g_week.hasTue)
      DrawDayLevels(p + "TUE", g_week.tueTime, g_week.tueHigh, g_week.tueLow, tEnd);
   DrawSeg(p + "LIQH", tStart, g_week.liqHigh, tEnd, g_week.liqHigh, InpLiqHighColor, 2, STYLE_SOLID);
   DrawSeg(p + "LIQL", tStart, g_week.liqLow, tEnd, g_week.liqLow, InpLiqLowColor, 2, STYLE_SOLID);

   //--- Tuesday D1 candle in yellow + its 50% line = TP1 (partial)
   if(g_week.hasTue)
     {
      datetime tueEnd = (datetime)((long)g_week.tueTime + 86400);
      DrawRect(p + "TUEBOX", g_week.tueTime, g_week.tueHigh, tueEnd, g_week.tueLow, InpTuesdayColor, false, 2, STYLE_SOLID, false);
      DrawSeg(p + "TUEMID", g_week.tueTime, g_week.tueMid, tEnd, g_week.tueMid, InpTuesdayColor, 2, STYLE_SOLID);
      DrawLabel(p + "TUEMID_T", tWed, g_week.tueMid, "TUESDAY 50% = TP1 PARTIAL  " + P2S(g_week.tueMid), InpTuesdayColor, ANCHOR_LEFT_LOWER);
     }
   ChartRedraw(0);
  }

void DrawOB(const SOrderBlock &ob)
  {
   if(!g_drawOn)
      return;
   string side = (ob.dir < 0) ? "S_" : "B_";
   string name = g_pfx + "OB_" + side + IntegerToString((long)ob.time);
   color c = (ob.dir < 0) ? InpBearOBColor : InpBullOBColor;
   string state = "";
   if(!ob.valid)
     {
      c = clrDimGray;
      state = " (mitigated)";
     }
   else
      if(ob.used)
        {
         c = clrSlateGray;
         state = " (traded)";
        }
   datetime tEnd = (datetime)((long)g_curWeekStart + 5 * 86400);
   string title = (ob.dir < 0) ? "H4 BEARISH OB" : "H4 BULLISH OB";
   DrawRect(name, ob.time, ob.high, tEnd, ob.low, c, true, 1, STYLE_SOLID, true);
   DrawLabel(name + "_T", ob.time, (ob.dir < 0) ? ob.high : ob.low, title + state, c, (ob.dir < 0) ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER);
  }

void DrawSignal(const bool isSell, const datetime t, const double price)
  {
   if(!g_drawOn)
      return;
   string name = g_pfx + "SIG_" + IntegerToString((long)t);
   if(ObjectFind(0, name) < 0)
      if(!ObjectCreate(0, name, OBJ_ARROW, 0, t, price))
         return;
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, isSell ? 234 : 233);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, isSell ? ANCHOR_BOTTOM : ANCHOR_TOP);
   ObjectSetInteger(0, name, OBJPROP_COLOR, isSell ? clrRed : clrLime);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 3);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Info panel                                                       |
//+------------------------------------------------------------------+
void PanelLine(const int idx, const string text, const color clr)
  {
   string name = g_pfx + "PANEL_L" + IntegerToString(idx);
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 18);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 30 + idx * 16);
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }

void UpdatePanel(void)
  {
   if(!InpShowPanel || !g_visual)
      return;
   g_lastPanelUpdate = TimeLocal();
   datetime now = ServerNow();
   int nP = 0, nR = 0;
   int open = CountOurPositions(nP, nR);
   MqlTick tick;
   double spread = SymbolInfoTick(_Symbol, tick) ? tick.ask - tick.bid : 0.0;
   SStats w;
   CalcStats(g_curWeekStart, (datetime)((long)now + 86400), w);
   int setups = (w.setups > g_setupsMem) ? w.setups : g_setupsMem;
   int nSell = 0, nBuy = 0;
   for(int i = 0; i < ArraySize(g_obs); i++)
      if(g_obs[i].valid && !g_obs[i].used)
        {
         if(g_obs[i].dir < 0)
            nSell++;
         else
            nBuy++;
        }

   string acc = g_netting ? "NETTING" : "HEDGING";
   string tg  = TgReady() ? "ON" : (InpTelegramEnable ? "check token / chat id" : "OFF");
   string L[];
   PushLine(L, g_eaName + " v" + g_eaVer + "  [" + acc + "]");
   PushLine(L, "Server " + DayTime(now) + "   spread " + P2S(spread));
   if(g_week.valid)
     {
      PushLine(L, "Liq HIGH " + P2S(g_week.liqHigh) + " (" + DayName(g_week.liqHighDow) + ")  Liq LOW "
               + P2S(g_week.liqLow) + " (" + DayName(g_week.liqLowDow) + ")");
      PushLine(L, "SELL zone " + P2S(g_week.sellBottom) + " - " + P2S(g_week.sellTop));
      PushLine(L, "BUY  zone " + P2S(g_week.buyBottom) + " - " + P2S(g_week.buyTop));
      PushLine(L, "TUE 50% (TP1 partial) " + (g_week.hasTue ? P2S(g_week.tueMid) : "n/a"));
      PushLine(L, "H4 OBs active: sell " + IntegerToString(nSell) + " / buy " + IntegerToString(nBuy));
     }
   else
      PushLine(L, "D1 zones: waiting for the Tuesday close");
   PushLine(L, "Setups " + IntegerToString(setups) + "/" + IntegerToString(InpMaxSetupsPerWeek)
            + "   open trades " + IntegerToString(open) + "   float " + SignedMoney(FloatingPL()));
   PushLine(L, "Week net " + SignedMoney(w.net) + " " + Currency());
   PushLine(L, "Weekly close " + DayTime(g_closeEffective));
   PushLine(L, "Status: " + StringSubstr(g_status, 0, 58));
   PushLine(L, "Telegram: " + tg);

   int n = ArraySize(L);
   string bg = g_pfx + "PANEL_BG";
   if(ObjectFind(0, bg) < 0)
     {
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, 24);
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, 440);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'18,20,26');
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_COLOR, C'70,70,80');
      ObjectSetInteger(0, bg, OBJPROP_BACK, false);
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
     }
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, n * 16 + 12);
   for(int k = 0; k < n; k++)
      PanelLine(k, L[k], (k == 0) ? clrGold : clrWhiteSmoke);
   for(int k2 = n; k2 < 25; k2++)
      ObjectDelete(0, g_pfx + "PANEL_L" + IntegerToString(k2));
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Telegram                                                         |
//+------------------------------------------------------------------+
bool TgReady(void)
  {
   if(!InpTelegramEnable || g_isTester)
      return false;
   return (StringLen(g_tgToken) > 20 && StringLen(g_tgChat) > 0);
  }

string JsonEscape(const string s)
  {
   string r = "";
   int len = StringLen(s);
   for(int i = 0; i < len; i++)
     {
      ushort c = StringGetCharacter(s, i);
      if(c == 34)
         r += "\\\"";
      else
         if(c == 92)
            r += "\\\\";
         else
            if(c == 10)
               r += "\\n";
            else
               if(c == 13)
                  r += "\\r";
               else
                  if(c == 9)
                     r += "\\t";
                  else
                     if(c < 32)
                        r += StringFormat("\\u%04x", (int)c);
                     else
                        r += ShortToString(c);
     }
   return r;
  }

ushort HexToUShort(const string h)
  {
   uint v = 0;
   int len = StringLen(h);
   for(int i = 0; i < len; i++)
     {
      ushort c = StringGetCharacter(h, i);
      uint d = 0;
      if(c >= '0' && c <= '9')
         d = (uint)(c - '0');
      else
         if(c >= 'a' && c <= 'f')
            d = (uint)(c - 'a' + 10);
         else
            if(c >= 'A' && c <= 'F')
               d = (uint)(c - 'A' + 10);
      v = v * 16 + d;
     }
   return (ushort)v;
  }

string JsonNumberAt(const string s, const int start)
  {
   string out = "";
   int len = StringLen(s);
   for(int i = start; i < len; i++)
     {
      ushort c = StringGetCharacter(s, i);
      if(c == ' ' && StringLen(out) == 0)
         continue;
      if((c >= '0' && c <= '9') || (c == '-' && StringLen(out) == 0))
         out += ShortToString(c);
      else
         break;
     }
   return out;
  }

string JsonStringAt(const string s, const int start)
  {
   string out = "";
   int len = StringLen(s);
   for(int i = start; i < len; i++)
     {
      ushort c = StringGetCharacter(s, i);
      if(c == 34)                            // closing quote
         break;
      if(c == 92 && i + 1 < len)             // escape sequence
        {
         ushort e = StringGetCharacter(s, i + 1);
         i++;
         if(e == 'n')
            out += "\n";
         else
            if(e == 't')
               out += "\t";
            else
               if(e == 'u' && i + 4 < len)
                 {
                  out += ShortToString(HexToUShort(StringSubstr(s, i + 1, 4)));
                  i += 4;
                 }
               else
                  out += ShortToString(e);
         continue;
        }
      out += ShortToString(c);
     }
   return out;
  }

bool TgPostJson(const string method, const string json, string &response, const int timeoutMs)
  {
   response = "";
   if(!TgReady())
      return false;
   string url = "https://api.telegram.org/bot" + g_tgToken + "/" + method;
   char data[];
   char result[];
   string resHeaders = "";
   int len = StringToCharArray(json, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(len > 0)
      ArrayResize(data, len - 1);            // drop the terminating zero
   ResetLastError();
   int code = WebRequest("POST", url, "Content-Type: application/json\r\n", timeoutMs, data, result, resHeaders);
   if(code == -1)
     {
      int err = GetLastError();
      if(!g_tgUrlWarned)
        {
         g_tgUrlWarned = true;
         string m = g_eaName + ": Telegram WebRequest failed (error " + IntegerToString(err)
                    + "). Add https://api.telegram.org in Tools > Options > Expert Advisors > Allow WebRequest for listed URL.";
         Print(m);
         Alert(m);
        }
      return false;
     }
   response = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   if(code != 200)
      Print("Telegram ", method, " HTTP ", code, ": ", StringSubstr(response, 0, 300));
   return (code == 200);
  }

void TgSend(const string text)
  {
   if(!InpTelegramEnable)
      return;
   if(g_isTester)
     {
      if(MQLInfoInteger(MQL_OPTIMIZATION) == 0)
        {
         int nl = StringFind(text, "\n");
         Print("[Telegram] ", (nl > 0) ? StringSubstr(text, 0, nl) : text);
        }
      return;
     }
   if(!TgReady())
      return;
   string t = text;
   if(StringLen(t) > 4000)
      t = StringSubstr(t, 0, 4000);
   string json = "{\"chat_id\":\"" + JsonEscape(g_tgChat) + "\",\"text\":\"" + JsonEscape(t)
                 + "\",\"disable_web_page_preview\":true}";
   string resp = "";
   TgPostJson("sendMessage", json, resp, 5000);
  }

void AppendText(char &buf[], const string s)
  {
   char tmp[];
   int n = StringToCharArray(s, tmp, 0, WHOLE_ARRAY, CP_UTF8);
   if(n <= 1)
      return;
   int old = ArraySize(buf);
   ArrayResize(buf, old + n - 1);
   ArrayCopy(buf, tmp, old, 0, n - 1);
  }

void TgSendScreenshot(const string caption)
  {
   if(!TgReady() || !InpTgScreenshot)
      return;
   string fname = "LSW_shot_" + IntegerToString(InpMagic) + ".png";
   ChartRedraw(0);
   if(!ChartScreenShot(0, fname, 1280, 720, ALIGN_RIGHT))
     {
      Print("ChartScreenShot failed: ", GetLastError());
      return;
     }
   int h = FileOpen(fname, FILE_READ | FILE_BIN);
   if(h == INVALID_HANDLE)
     {
      Print("Screenshot file open failed: ", GetLastError());
      return;
     }
   int size = (int)FileSize(h);
   char img[];
   ArrayResize(img, size);
   uint got = (size > 0) ? FileReadArray(h, img, 0, size) : 0;
   FileClose(h);
   FileDelete(fname);
   if(size <= 0 || (int)got != size)
      return;

   string cap = caption;
   if(StringLen(cap) > 1000)
      cap = StringSubstr(cap, 0, 1000);
   string boundary = "LSWboundary" + IntegerToString(GetTickCount()) + IntegerToString(MathRand());
   char body[];
   AppendText(body, "--" + boundary + "\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n" + g_tgChat + "\r\n");
   AppendText(body, "--" + boundary + "\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\n" + cap + "\r\n");
   AppendText(body, "--" + boundary + "\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"chart.png\"\r\nContent-Type: image/png\r\n\r\n");
   int old = ArraySize(body);
   ArrayResize(body, old + size);
   ArrayCopy(body, img, old, 0, size);
   AppendText(body, "\r\n--" + boundary + "--\r\n");

   string url = "https://api.telegram.org/bot" + g_tgToken + "/sendPhoto";
   char result[];
   string rh = "";
   ResetLastError();
   int code = WebRequest("POST", url, "Content-Type: multipart/form-data; boundary=" + boundary + "\r\n", 20000, body, result, rh);
   if(code != 200)
      Print("Telegram sendPhoto failed: HTTP ", code, " error ", GetLastError(), " ",
            StringSubstr(CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8), 0, 200));
  }

string HelpText(void)
  {
   return E_Bot() + " " + g_eaName + " - commands\n"
          + "/status - EA status, open trades, P/L\n"
          + "/zones - D1 liquidity zones, Tuesday 50% TP1, H4 order blocks\n"
          + "/report - today + this week results\n"
          + "/chart - chart screenshot\n"
          + "/help - this list";
  }

void TgHandleCommand(const string raw)
  {
   string cmd = raw;
   StringTrimLeft(cmd);
   StringTrimRight(cmd);
   StringToLower(cmd);
   int sp = StringFind(cmd, " ");
   if(sp > 0)
      cmd = StringSubstr(cmd, 0, sp);
   int at = StringFind(cmd, "@");
   if(at > 0)
      cmd = StringSubstr(cmd, 0, at);
   if(cmd == "/status")
      TgSend(BuildStatusText());
   else
      if(cmd == "/zones")
         TgSend(BuildZonesText());
      else
         if(cmd == "/report")
            TgSend(BuildDailyReport(DayStart(ServerNow())));
         else
            if(cmd == "/chart")
               TgSendScreenshot(_Symbol + " - " + DayTime(ServerNow()) + " (server)");
            else
               if(cmd == "/help" || cmd == "/start")
                  TgSend(HelpText());
  }

void TgPollCommands(void)
  {
   if(!TgReady() || !InpTgCommands)
      return;
   string json = "{\"offset\":" + IntegerToString(g_tgOffset + 1) + ",\"timeout\":0,\"limit\":20}";
   string resp = "";
   if(!TgPostJson("getUpdates", json, resp, 3000))
      return;
   if(StringFind(resp, "\"ok\":true") < 0)
      return;

   string keyUpd  = "\"update_id\":";
   string keyChat = "\"chat\":{\"id\":";
   string keyDate = "\"date\":";
   string keyText = "\"text\":\"";
   int lenUpd = StringLen(keyUpd);
   bool changed = false;
   int pos = StringFind(resp, keyUpd);
   while(pos >= 0)
     {
      int next = StringFind(resp, keyUpd, pos + lenUpd);
      string block = (next < 0) ? StringSubstr(resp, pos) : StringSubstr(resp, pos, next - pos);
      long uid = StringToInteger(JsonNumberAt(block, lenUpd));
      if(uid > g_tgOffset)
        {
         g_tgOffset = uid;
         changed = true;
        }
      string chat = "";
      int c = StringFind(block, keyChat);
      if(c >= 0)
         chat = JsonNumberAt(block, c + StringLen(keyChat));
      long msgDate = 0;
      int dp = StringFind(block, keyDate);
      if(dp >= 0)
         msgDate = StringToInteger(JsonNumberAt(block, dp + StringLen(keyDate)));
      string text = "";
      int tp = StringFind(block, keyText);
      if(tp >= 0)
         text = JsonStringAt(block, tp + StringLen(keyText));
      bool fresh = (msgDate == 0 || msgDate >= (long)TimeGMT() - 180);   // ignore old backlog
      if(chat == g_tgChat && fresh && StringLen(text) > 0)
         TgHandleCommand(text);
      pos = next;
     }
   if(changed)
      GlobalVariableSet(GVName("tgoffset"), (double)g_tgOffset);
  }

//+------------------------------------------------------------------+
//| Reports                                                          |
//+------------------------------------------------------------------+
string BuildZonesText(void)
  {
   string s = E_Chart() + " D1 LIQUIDITY MAP - " + _Symbol + " - week of " + TimeToString(g_curWeekStart, TIME_DATE) + "\n";
   if(!g_week.valid)
      return s + "Zones are built after the Tuesday D1 candle closes (Wednesday 00:00 server).";
   if(g_week.hasFri)
      s += DayName(DowOf(g_week.friTime)) + " (prev week)  H " + P2S(g_week.friHigh) + "  L " + P2S(g_week.friLow) + "\n";
   if(g_week.hasMon)
      s += "Mon  H " + P2S(g_week.monHigh) + "  L " + P2S(g_week.monLow) + "\n";
   if(g_week.hasTue)
      s += "Tue  H " + P2S(g_week.tueHigh) + "  L " + P2S(g_week.tueLow) + "\n";
   s += E_Red() + " SELL zone: " + P2S(g_week.sellBottom) + " - " + P2S(g_week.sellTop)
        + "  (liquidity high " + P2S(g_week.liqHigh) + " " + DayName(g_week.liqHighDow) + ")\n";
   s += E_Green() + " BUY zone: " + P2S(g_week.buyBottom) + " - " + P2S(g_week.buyTop)
        + "  (liquidity low " + P2S(g_week.liqLow) + " " + DayName(g_week.liqLowDow) + ")\n";
   string tue = g_week.hasTue ? P2S(g_week.tueMid) : "n/a (fallback " + DoubleToString(InpFallbackPartialRR, 1) + "R)";
   s += E_Yellow() + " TP1 partial = Tuesday 50%: " + tue + "\n";
   s += E_Target() + " TP2 full = 1:" + DoubleToString(InpRewardRisk, 1) + " risk reward\n";
   s += OBListText();
   s += E_Clock() + " Entries Wed / Thu / Fri | weekly close " + DayTime(g_closeEffective) + " (server)";
   return s;
  }

string BuildStatusText(void)
  {
   datetime now = ServerNow();
   int nP = 0, nR = 0;
   int n = CountOurPositions(nP, nR);
   string s = E_Bot() + " STATUS - " + _Symbol + "\n";
   s += "Server: " + DayTime(now) + "\n";
   s += "EA: " + g_status + "\n";
   s += "Setups this week: " + IntegerToString(SetupsThisWeek()) + "/" + IntegerToString(InpMaxSetupsPerWeek) + "\n";
   s += "Open trades: " + IntegerToString(n) + "\n" + OpenPositionsText();
   s += "Floating: " + SignedMoney(FloatingPL()) + " " + Currency() + "\n";
   s += "Balance: " + M2S(AccountInfoDouble(ACCOUNT_BALANCE)) + " | Equity: " + M2S(AccountInfoDouble(ACCOUNT_EQUITY)) + "\n";
   s += "Weekly close: " + DayTime(g_closeEffective) + " (server)";
   return s;
  }

string BuildDailyReport(const datetime dayStart)
  {
   SStats d, w;
   CalcStats(dayStart, (datetime)((long)dayStart + 86400), d);
   CalcStats(g_curWeekStart, (datetime)((long)ServerNow() + 86400), w);
   string s = E_Chart() + " DAILY REPORT - " + _Symbol + " - " + DayName(DowOf(dayStart)) + " " + TimeToString(dayStart, TIME_DATE) + "\n";
   s += "Today: closed " + IntegerToString(d.closed) + " | W " + IntegerToString(d.wins) + " / L " + IntegerToString(d.losses)
        + " | Net " + SignedMoney(d.net) + " " + Currency() + "\n";
   s += "This week: setups " + IntegerToString(w.setups) + "/" + IntegerToString(InpMaxSetupsPerWeek) + " | closed "
        + IntegerToString(w.closed) + " | Net " + SignedMoney(w.net) + " " + Currency() + "\n";
   s += "Open trades:\n" + OpenPositionsText();
   s += "Balance: " + M2S(AccountInfoDouble(ACCOUNT_BALANCE)) + " | Equity: " + M2S(AccountInfoDouble(ACCOUNT_EQUITY)) + "\n";
   s += "Status: " + g_status;
   return s;
  }

string BuildWeeklyReport(const datetime ws)
  {
   SStats w;
   CalcStats(ws, (datetime)((long)ws + 7 * 86400), w);
   int decided = w.wins + w.losses;
   double wr = (decided > 0) ? 100.0 * w.wins / decided : 0.0;
   string s = E_Cal() + " WEEKLY REPORT - " + _Symbol + " - week of " + TimeToString(ws, TIME_DATE) + "\n";
   s += "Setups: " + IntegerToString(w.setups) + "/" + IntegerToString(InpMaxSetupsPerWeek) + " (each = TP1 partial + TP2 full)\n";
   s += "Trades closed: " + IntegerToString(w.closed) + " | Wins " + IntegerToString(w.wins) + " | Losses " + IntegerToString(w.losses)
        + " | Win rate " + DoubleToString(wr, 1) + "%\n";
   s += "Net P/L: " + SignedMoney(w.net) + " " + Currency() + "\n";
   s += "Balance: " + M2S(AccountInfoDouble(ACCOUNT_BALANCE)) + " | Equity: " + M2S(AccountInfoDouble(ACCOUNT_EQUITY)) + "\n";
   s += E_Ok() + " Week finished - no trades held over the weekend.";
   return s;
  }

void DailyReportCheck(const datetime now)
  {
   if(!InpTelegramEnable || !InpTgDailyReport)
      return;
   int dow = DowOf(now);
   if(dow == 0 || dow == 6)
      return;
   if(MinuteOfDay(now) < InpTgDailyHour * 60 + InpTgDailyMinute)
      return;
   datetime today = DayStart(now);
   string gv = GVName("daily");
   if(GlobalVariableCheck(gv) && (long)GlobalVariableGet(gv) >= (long)today)
      return;
   GlobalVariableSet(gv, (double)today);
   TgSend(BuildDailyReport(today));
  }

void WeeklyReportCheck(const datetime now)
  {
   if(!InpTelegramEnable || g_closeEffective == 0 || now < g_closeEffective)
      return;
   int nP = 0, nR = 0;
   if(CountOurPositions(nP, nR) > 0)
      return;                                // wait until everything is closed
   string gv = GVName("weekly");
   if(GlobalVariableCheck(gv) && (long)GlobalVariableGet(gv) >= (long)g_curWeekStart)
      return;
   GlobalVariableSet(gv, (double)g_curWeekStart);
   TgSend(BuildWeeklyReport(g_curWeekStart));
  }

//+------------------------------------------------------------------+
//| Weekly zone set-up                                               |
//+------------------------------------------------------------------+
void TryBuildWeek(void)
  {
   if(!BuildWeeklyLiquidity(g_curWeekStart))
      return;
   ScanOrderBlocks(false);
   g_lastH4Bar = iTime(_Symbol, PERIOD_H4, 0);
   DrawWeek();
   g_status = "D1 zones ready - watching H4 order blocks";
   string gv = GVName("zones");
   bool sent = GlobalVariableCheck(gv) && (long)GlobalVariableGet(gv) >= (long)g_curWeekStart;
   if(!sent)
     {
      GlobalVariableSet(gv, (double)g_curWeekStart);
      TgSend(BuildZonesText());
      TgSendScreenshot(_Symbol + " - D1 sell / buy zones, Tuesday 50% (yellow) and H4 order blocks");
     }
   UpdatePanel();
  }

void PeriodicChecks(const datetime now)
  {
   EnsureWeek(now);
   CheckWeeklyClose(now);
   WeeklyReportCheck(now);
   DailyReportCheck(now);
  }

bool ValidateInputs(void)
  {
   string e = "";
   if(InpRewardRisk <= 0)
      e = "Reward:risk must be > 0";
   else
      if(InpPartialLegPct <= 0 || InpPartialLegPct >= 100)
         e = "TP1 trade % must be between 0 and 100";
      else
         if(InpLotMode == LOT_RISK_PERCENT && InpRiskPercent <= 0)
            e = "Risk % must be > 0";
         else
            if(InpLotMode == LOT_FIXED && InpFixedLot <= 0)
               e = "Fixed lot must be > 0";
            else
               if(InpMaxSetupsPerWeek < 1)
                  e = "Setups per week must be >= 1";
               else
                  if(InpCloseHour < 0 || InpCloseHour > 23 || InpCloseMinute < 0 || InpCloseMinute > 59)
                     e = "Weekly close time is invalid";
                  else
                     if(InpMaxSL <= InpMinSL)
                        e = "Max SL must be greater than min SL";
                     else
                        if(InpOBLookback < 5 || InpOBImpulseBars < 1 || InpMaxOBsPerSide < 1)
                           e = "Order block settings are invalid";
                        else
                           if(InpZoneDepthPct <= 0 || InpZoneDepthPct >= 50)
                              e = "Zone depth % must be between 0 and 50";
                           else
                              if(InpATRPeriod < 2)
                                 e = "ATR period must be >= 2";
   if(e != "")
     {
      Alert(g_eaName, ": ", e);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_isTester = (MQLInfoInteger(MQL_TESTER) != 0);
   g_visual   = (!g_isTester || MQLInfoInteger(MQL_VISUAL_MODE) != 0) && MQLInfoInteger(MQL_OPTIMIZATION) == 0;
   g_drawOn   = InpDraw && g_visual;
   g_magicP   = InpMagic;
   g_magicR   = InpMagic + 1;

   string sym = _Symbol;
   StringToUpper(sym);
   if(InpOnlyGold && StringFind(sym, "XAU") < 0 && StringFind(sym, "GOLD") < 0)
     {
      Alert(g_eaName, ": attach the EA to an XAUUSD / GOLD chart (or set 'Only run on gold symbols' = false).");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!ValidateInputs())
      return INIT_PARAMETERS_INCORRECT;

   g_netting = (AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   ConfigureTrade(g_tradeP, g_magicP);
   ConfigureTrade(g_tradeR, g_magicR);

   g_hAtrD1 = iATR(_Symbol, PERIOD_D1, InpATRPeriod);
   g_hAtrH4 = iATR(_Symbol, PERIOD_H4, InpATRPeriod);
   g_hAtrM5 = iATR(_Symbol, PERIOD_M5, InpATRPeriod);
   if(g_hAtrD1 == INVALID_HANDLE || g_hAtrH4 == INVALID_HANDLE || g_hAtrM5 == INVALID_HANDLE)
     {
      Print(g_eaName, ": failed to create ATR handles, error ", GetLastError());
      return INIT_FAILED;
     }

   g_tgToken = InpTelegramToken;
   g_tgChat  = InpTelegramChatId;
   StringTrimLeft(g_tgToken);
   StringTrimRight(g_tgToken);
   StringTrimLeft(g_tgChat);
   StringTrimRight(g_tgChat);
   if(GlobalVariableCheck(GVName("tgoffset")))
      g_tgOffset = (long)GlobalVariableGet(GVName("tgoffset"));

   g_curWeekStart = 0;
   g_lastM5Bar    = 0;
   g_lastH4Bar    = 0;
   EnsureWeek(ServerNow());

   if(!g_isTester)
      EventSetTimer(1);

   if(g_netting)
      Print(g_eaName, ": NETTING account detected - one position per setup, TP1 is closed by the EA (partial close).");

   if(InpTelegramEnable && !g_isTester)
     {
      if(!TgReady())
         Print(g_eaName, ": Telegram is enabled but the bot token / chat id is missing.");
      else
        {
         string risk = (InpLotMode == LOT_RISK_PERCENT) ? DoubleToString(InpRiskPercent, 2) + "% per setup"
                       : L2S(InpFixedLot) + " lot per trade";
         string acc  = g_netting ? "netting" : "hedging";
         TgSend(E_Bot() + " " + g_eaName + " v" + g_eaVer + " started\n"
                + "Symbol: " + _Symbol + " | Account " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + " (" + acc + ")\n"
                + "Risk: " + risk + " | TP1 Tuesday 50% + TP2 1:" + DoubleToString(InpRewardRisk, 1) + "\n"
                + "Entries: Wed / Thu / Fri | Weekly close " + DayTime(g_closeEffective) + " (server)\n"
                + "Send /help for commands.");
        }
     }

   g_status = "Initialised - waiting for market data";
   UpdatePanel();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_hAtrD1 != INVALID_HANDLE)
      IndicatorRelease(g_hAtrD1);
   if(g_hAtrH4 != INVALID_HANDLE)
      IndicatorRelease(g_hAtrH4);
   if(g_hAtrM5 != INVALID_HANDLE)
      IndicatorRelease(g_hAtrM5);
   ObjectsDeleteAll(0, g_pfx + "PANEL");
   if(reason == REASON_REMOVE && !g_isTester)
      ObjectsDeleteAll(0, g_pfx);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime now = TimeCurrent();
   PeriodicChecks(now);
   ManageVirtualPartial();

   datetime m5 = iTime(_Symbol, PERIOD_M5, 0);
   bool newM5  = (m5 > 0 && m5 != g_lastM5Bar);

   //--- D1 zones: built once per week, after the Tuesday candle closed (retried each M5 bar until data is ready)
   if(newM5 && !g_week.valid && (long)now >= (long)g_curWeekStart + 2 * 86400)
      TryBuildWeek();

   //--- H4 order blocks: rescan on every new H4 candle
   datetime h4 = iTime(_Symbol, PERIOD_H4, 0);
   if(g_week.valid && h4 > 0 && h4 != g_lastH4Bar)
     {
      g_lastH4Bar = h4;
      ScanOrderBlocks(true);
     }

   //--- M5: entries and trade management on every new M5 candle
   if(newM5)
     {
      g_lastM5Bar = m5;
      ManageBreakeven();
      if(g_week.valid)
         CheckEntries();
      else
         if(DowOf(now) == 1 || DowOf(now) == 2)
            g_status = "Mon / Tue: Fri-Mon-Tue liquidity forming - no trading";
      UpdatePanel();
     }
  }

//+------------------------------------------------------------------+
//| Timer (live only): weekly close without ticks, reports, commands |
//+------------------------------------------------------------------+
void OnTimer()
  {
   PeriodicChecks(ServerNow());
   datetime local = TimeLocal();
   if(TgReady() && InpTgCommands && (long)local - (long)g_lastTgPoll >= InpTgPollSeconds)
     {
      g_lastTgPoll = local;
      TgPollCommands();
     }
   if((long)local - (long)g_lastPanelUpdate >= 5)
      UpdatePanel();
  }

//+------------------------------------------------------------------+
//| Trade events: TP1 / TP2 / SL / weekly close reports              |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;
   if(trans.symbol != _Symbol)
      return;
   ulong deal = trans.deal;
   if(!HistoryDealSelect(deal))
     {
      HistorySelect((datetime)((long)TimeCurrent() - 30 * 86400), (datetime)((long)TimeCurrent() + 86400));
      if(!HistoryDealSelect(deal))
         return;
     }
   long magic = HistoryDealGetInteger(deal, DEAL_MAGIC);
   if(!IsOurMagic(magic))
      return;
   long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;

   long reason   = HistoryDealGetInteger(deal, DEAL_REASON);
   double profit = HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP)
                   + HistoryDealGetDouble(deal, DEAL_COMMISSION) + HistoryDealGetDouble(deal, DEAL_FEE);
   double price  = HistoryDealGetDouble(deal, DEAL_PRICE);
   double vol    = HistoryDealGetDouble(deal, DEAL_VOLUME);
   long posId    = HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   bool stillOpen = PositionOpenById(posId);
   bool tp1Leg   = (magic == g_magicP && !g_netting);

   string title = "";
   if(reason == DEAL_REASON_TP)
      title = tp1Leg ? E_Yellow() + " TP1 HIT - partial taken at the Tuesday 50%"
              : E_Target() + " TP2 HIT - full target 1:" + DoubleToString(InpRewardRisk, 1);
   else
      if(reason == DEAL_REASON_SL)
         title = (profit >= 0) ? E_Shield() + " Stopped at breakeven / in profit" : E_Stop() + " STOP LOSS HIT";
      else
         if(reason == DEAL_REASON_SO)
            title = E_Warn() + " STOP OUT (margin)";
         else
            if(reason == DEAL_REASON_EXPERT)
              {
               if(g_netting && stillOpen)
                  title = E_Yellow() + " TP1 HIT - partial closed at the Tuesday 50%";
               else
                  title = E_Clock() + " " + (g_lastCloseReason != "" ? g_lastCloseReason : "Closed by the EA");
              }
            else
               title = E_Warn() + " Closed manually / externally";

   string leg = tp1Leg ? "Trade 1 (TP1 partial)" : (magic == g_magicR ? "Trade 2 (TP2 full)" : "Position");
   string msg = title + "\n"
                + _Symbol + " " + leg + " | " + L2S(vol) + " lot @ " + P2S(price) + "\n"
                + "Result: " + SignedMoney(profit) + " " + Currency() + "\n"
                + "Balance: " + M2S(AccountInfoDouble(ACCOUNT_BALANCE)) + " | Equity: " + M2S(AccountInfoDouble(ACCOUNT_EQUITY));
   Print(_Symbol, " ", leg, " closed @ ", P2S(price), " result ", SignedMoney(profit));
   TgSend(msg);

   ManageBreakeven();
   UpdatePanel();
  }
//+------------------------------------------------------------------+
