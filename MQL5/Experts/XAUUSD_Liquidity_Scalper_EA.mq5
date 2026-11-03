//+------------------------------------------------------------------+
//|                                XAUUSD_Liquidity_Scalper_EA.mq5   |
//|                                                                  |
//|  SCALPING MODEL - liquidity sweep -> M1 change of character      |
//|  1. Liquidity levels mapped every day:                           |
//|       - previous day high / low (PDH / PDL)                      |
//|       - Asian range high / low (00:00-06:00 GMT)                 |
//|       - unswept H1 swing highs / lows (last 24 hours)            |
//|  2. In the London / New York killzones price must SWEEP a level: |
//|     trade through it by 0.1 - 1.5 x M5 ATR (more = breakout).    |
//|  3. Then an M1 ChoCH: a close through the last M1 swing that     |
//|     formed before the sweep, with a fair value gap (displacement)|
//|  4. Market entry, SL beyond the sweep extreme, 2 trades:         |
//|       trade 1 -> TP1 at 1R (partial)                             |
//|       trade 2 -> TP2 at 2R (or ATR trailing), breakeven at TP1.  |
//|  5. Risk control: max setups per day, stop after N losing        |
//|     setups in a row, daily loss limit, daily / weekly profit     |
//|     target, cooldown, max hold time, close before the daily      |
//|     rollover, before the weekend and before high-impact news.    |
//|  6. Filters: killzones, news, spread, M5 volatility, H1 bias.     |
//|  7. Telegram: liquidity map, entries, exits, daily / weekly      |
//|     reports, /status /levels /report /news /diag /chart /help.   |
//|  8. Diagnostics: every signal not traded is logged with reason.  |
//|                                                                  |
//|  Runs next to XAUUSD_Liquidity_Swing_EA (own magic number,       |
//|  own chart objects "LSC_").                                      |
//+------------------------------------------------------------------+
#property copyright   "xauusd-pro-calculator"
#property link        "https://github.com/vinada08/xauusd-pro-calculator-"
#property version     "1.00"
#property description "XAUUSD scalper: liquidity sweep (PDH/PDL, Asian range, H1 swings) -> M1 ChoCH + FVG entry."
#property description "2 trades per setup: TP1 1R + TP2 2R / ATR trail. Killzones, news, spread, volatility, H1 bias."
#property description "Daily limits (setups, losses in a row, max loss, target), weekly target. Telegram reports."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_LOT_MODE
  {
   LOT_RISK_PERCENT = 0,   // Risk % of balance (split between the 2 trades)
   LOT_FIXED        = 1    // Fixed lot for each of the 2 trades
  };

enum ENUM_TP2_MODE
  {
   TP2_FIXED_RR      = 0,  // Fixed 1:RR target (no trailing)
   TP2_ATR_TRAIL     = 1,  // ATR trailing stop after TP1 (no fixed target)
   TP2_RR_PLUS_TRAIL = 2   // 1:RR target + ATR trailing stop after TP1
  };

enum ENUM_TREND_MODE
  {
   TREND_OFF              = 0, // Off (trade both directions)
   TREND_MA               = 1, // Moving average (price vs MA + slope)
   TREND_STRUCTURE        = 2, // Market structure (HH/HL vs LH/LL)
   TREND_MA_AND_STRUCTURE = 3  // MA and structure must agree
  };

enum ENUM_ENTRY_CONFIRM
  {
   CONFIRM_REJECTION       = 0, // Rejection candle at the sweep only (fastest)
   CONFIRM_CHOCH           = 1, // M1 ChoCH after the sweep (recommended)
   CONFIRM_REJECTION_CHOCH = 2  // Rejection candle + M1 ChoCH (strictest)
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== General ==="
input long            InpMagic                = 270511;          // Magic number (TP1 trade = magic, TP2 trade = magic+1)
input string          InpComment              = "XAU Scalp";     // Order comment
input bool            InpOnlyGold             = true;            // Only run on gold symbols (XAU / GOLD)
input bool            InpLogSignals           = true;            // Journal: log every signal and why it was not taken

input group "=== Trading days & times (server time) ==="
input bool            InpTradeMonday          = true;            // Trade on Monday
input bool            InpTradeTuesday         = true;            // Trade on Tuesday
input bool            InpTradeWednesday       = true;            // Trade on Wednesday
input bool            InpTradeThursday        = true;            // Trade on Thursday
input bool            InpTradeFriday          = true;            // Trade on Friday
input int             InpLastEntryHour        = 22;              // No new entries from this hour (server)
input int             InpFridayLastEntryHour  = 18;              // Friday: no new entries from this hour (server)
input bool            InpUseDailyClose        = true;            // Close all scalps at the daily close time
input int             InpDailyCloseHour       = 23;              // Daily close hour (server) - before the rollover spread
input int             InpDailyCloseMinute     = 30;              // Daily close minute (server)
input int             InpMaxHoldMinutes       = 120;             // Close a scalp after N minutes (0 = off)
input int             InpCloseBeforeMarketMin = 15;              // Friday: close N minutes before the market close
input double          InpTesterBrokerGMT      = 2.0;             // Tester: broker GMT offset in winter (live = auto)
input bool            InpTesterUSDST          = true;            // Tester: broker adds +1h during US summer time
input int             InpFallbackCloseHour    = 23;              // Fallback Friday market close hour (server) if unknown
input int             InpFallbackCloseMin     = 55;              // Fallback Friday market close minute (server)

input group "=== Killzones (local exchange time, DST-aware) ==="
input bool            InpUseSessionFilter     = true;            // Only enter inside the selected killzones
input bool            InpSessLondon           = true;            // London killzone
input int             InpLondonStartHour      = 7;               // London start hour (London local time)
input int             InpLondonEndHour        = 10;              // London end hour (London local time)
input bool            InpSessNewYork          = true;            // New York killzone
input int             InpNYStartHour          = 8;               // New York start hour (New York local time)
input int             InpNYEndHour            = 11;              // New York end hour (New York local time)
input bool            InpSessAsia             = false;           // Asian session (Tokyo)
input int             InpAsiaStartHour        = 9;               // Asia start hour (Tokyo local time)
input int             InpAsiaEndHour          = 12;              // Asia end hour (Tokyo local time)

input group "=== Liquidity levels ==="
input bool            InpLiqAsia              = true;            // Asian range high / low
input int             InpAsiaRangeStartGMT    = 0;               // Asian range start (GMT hour)
input int             InpAsiaRangeEndGMT      = 6;               // Asian range end (GMT hour)
input bool            InpLiqPrevDay           = true;            // Previous day high / low
input bool            InpLiqH1Swings          = true;            // Unswept H1 swing highs / lows
input int             InpH1SwingLookback      = 24;              // H1 bars scanned for swings
input int             InpH1SwingStrength      = 2;               // H1 swing strength (bars each side)
input double          InpSweepMinATR          = 0.10;            // A sweep pierces the level by >= x M5 ATR
input double          InpSweepMaxATR          = 1.50;            // ... and by <= x M5 ATR (a close beyond = breakout)

input group "=== M1 entry (sweep -> ChoCH) ==="
input ENUM_ENTRY_CONFIRM InpEntryConfirm      = CONFIRM_CHOCH;   // Entry confirmation
input int             InpChochSwingBars       = 2;               // ChoCH: M1 swing strength (bars each side)
input int             InpChochWindow          = 30;              // ChoCH: max M1 bars from the sweep to the break
input int             InpChochSwingLookback   = 20;              // ChoCH: M1 bars searched for the swing before the sweep
input bool            InpRequireFVG           = true;            // The displacement must leave an M1 fair value gap
input bool            InpUsePinBar            = true;            // Rejection: pin bar / long wick
input double          InpPinMinWickPct        = 50.0;            // Rejection wick >= % of candle range
input double          InpPinMaxBodyPct        = 40.0;            // Candle body <= % of candle range
input bool            InpUseEngulfing         = true;            // Rejection: engulfing candle
input double          InpMinCandleATR         = 0.30;            // Rejection candle range >= x M1 ATR

input group "=== Risk & targets ==="
input ENUM_LOT_MODE   InpLotMode              = LOT_RISK_PERCENT; // Lot sizing mode
input double          InpRiskPercent          = 0.5;             // Total risk per setup in % of balance (both trades)
input double          InpFixedLot             = 0.01;            // Fixed lot per trade (fixed mode)
input double          InpPartialLegPct        = 50.0;            // % of the setup volume on the TP1 (partial) trade
input double          InpMaxRiskPercent       = 2.0;             // Skip if min-lot rounding pushes risk above this %
input double          InpTP1RR                = 1.0;             // TP1 (partial) at x R
input double          InpRewardRisk           = 2.0;             // TP2 at x R
input ENUM_TP2_MODE   InpTP2Mode              = TP2_FIXED_RR;    // TP2 trade exit
input ENUM_TIMEFRAMES InpTrailTF              = PERIOD_M5;       // Trailing ATR timeframe
input int             InpTrailATRPeriod       = 14;              // Trailing ATR period
input double          InpTrailATRMult         = 1.5;             // Trailing distance (x ATR)
input double          InpTrailStep            = 0.30;            // Minimum SL improvement per trail move (price, $)
input double          InpTrailHardTPRR        = 0.0;             // ATR-trail mode: optional far TP in R (0 = none)
input bool            InpMoveRunnerToBE       = true;            // Move the TP2 trade to breakeven when TP1 is hit
input double          InpBEOffset             = 0.10;            // Breakeven offset in profit (price, $)
input double          InpSLBuffer             = 0.20;            // SL buffer beyond the sweep extreme (price, $)
input double          InpMinSL                = 1.50;            // Minimum SL distance (price, $)
input double          InpMaxSL                = 0.0;             // Maximum SL distance (price, $) - 0 = automatic
input double          InpMaxSLATR             = 2.5;             // Automatic maximum SL = x M15 ATR (when max SL = 0)
input double          InpMaxSpread            = 0.40;            // Maximum spread for entries (price, $)
input int             InpSlippagePoints       = 20;              // Maximum slippage (points)
input double          InpMinATR               = 0.0;             // Minimum M5 ATR (price, $, 0 = off) - skip dead markets
input double          InpMaxATR               = 0.0;             // Maximum M5 ATR (price, $, 0 = off) - skip extreme volatility
input int             InpATRPeriod            = 14;              // ATR period (M1 / M5 / M15)

input group "=== Daily / weekly limits ==="
input int             InpMaxTradesPerDay      = 4;               // Max setups per day (each = TP1 trade + TP2 trade)
input int             InpMaxConsecLosses      = 2;               // Stop for the day after N losing setups in a row (0 = off)
input double          InpDailyMaxLossPct      = 2.0;             // Daily loss limit in % of the day's start balance (0 = off)
input double          InpDailyProfitTarget    = 0.0;             // Daily profit target in account currency (0 = off)
input double          InpWeeklyProfitTarget   = 250.0;           // Weekly profit target in account currency (0 = off)
input bool            InpTargetIncludeFloating= true;            // Count open trades' floating P/L toward the targets
input bool            InpTargetCloseTrades    = true;            // Close open trades when a profit target is reached
input int             InpCooldownMinutes      = 10;              // Wait N minutes after a setup closes

input group "=== High-impact news filter ==="
input bool            InpUseNewsFilter        = true;            // Pause new entries around high-impact news
input string          InpNewsCurrencies       = "USD";           // News currencies (comma separated, e.g. USD,EUR)
input bool            InpNewsIncludeMedium    = false;           // Also pause for medium-impact news
input int             InpNewsMinsBefore       = 30;              // Pause minutes BEFORE the news
input int             InpNewsMinsAfter        = 30;              // Pause minutes AFTER the news
input int             InpNewsCloseMinsBefore  = 5;               // Close open scalps N minutes before the news (0 = off)
input string          InpNewsKeywords         = "";              // Only events containing (comma separated, empty = all)
input bool            InpNewsNFPRule          = true;            // No calendar (tester): block NFP, 1st Friday 08:30 New York
input string          InpNewsManualTimes      = "";              // Extra news, server time: 2026.11.06 15:30;2026.11.12 15:30

input group "=== HTF bias filter ==="
input ENUM_TREND_MODE InpTrendMode            = TREND_MA;        // Bias filter mode
input ENUM_TIMEFRAMES InpTrendTF              = PERIOD_H1;       // Bias timeframe
input int             InpTrendMAPeriod        = 50;              // Bias MA period
input ENUM_MA_METHOD  InpTrendMAMethod        = MODE_EMA;        // Bias MA method
input int             InpTrendSlopeBars       = 3;               // MA must slope over N bars (0 = no slope check)
input int             InpTrendSwingBars       = 3;               // Structure: swing strength (bars each side)
input int             InpTrendLookback        = 120;             // Structure: bars to scan
input bool            InpTrendBlockNeutral    = false;           // No trades when the bias is neutral / mixed

input group "=== Chart ==="
input bool            InpDraw                 = true;            // Draw the liquidity levels
input bool            InpShowPanel            = true;            // Show the info panel
input color           InpAsiaColor            = C'38,38,72';     // Asian range box
input color           InpLevelHighColor       = clrTomato;       // Buy-side liquidity (highs)
input color           InpLevelLowColor        = clrLimeGreen;    // Sell-side liquidity (lows)

input group "=== Telegram report bot ==="
input bool            InpTelegramEnable       = false;           // Enable Telegram reports
input string          InpTelegramToken        = "";              // Bot token from @BotFather
input string          InpTelegramChatId       = "";              // Chat id (user, group or channel)
input bool            InpTgScreenshot         = true;            // Attach chart screenshots (levels / entries)
input bool            InpTgCommands           = true;            // Answer /status /levels /report /news /diag /chart /help
input int             InpTgPollSeconds        = 10;              // Command polling interval (seconds)
input bool            InpTgNewsAlerts         = true;            // Message when a news pause starts
input bool            InpTgNotifyTrail        = false;           // Message on every trailing stop move
input bool            InpTgDailyReport        = true;            // Send a daily report (Mon-Fri)
input int             InpTgDailyHour          = 23;              // Daily report hour (server time)
input int             InpTgDailyMinute        = 0;               // Daily report minute (server time)

//+------------------------------------------------------------------+
//| Data structures                                                  |
//+------------------------------------------------------------------+
struct SOrderBlock                         // a point of interest: the sweep band beyond a level
  {
   datetime          time;
   double            high;
   double            low;
   int               dir;                  // -1 = sell (high was swept), +1 = buy (low was swept)
   bool              valid;
   bool              used;
  };

struct SLevel
  {
   double            price;
   int               side;                 // +1 = high (buy-side liquidity), -1 = low (sell-side liquidity)
   int               kind;                 // 0 = previous day, 1 = Asian range, 2 = H1 swing
   datetime          time;                 // when the level was formed
   bool              broken;               // price accepted beyond it (breakout) - done for the day
   bool              used;                 // a setup was taken from it
  };

struct SStats
  {
   int               setups;
   int               closed;
   int               wins;
   int               losses;
   double            net;
  };

struct SNewsEvent
  {
   datetime          time;                 // server time
   string            name;
   string            currency;
   bool              high;                 // high impact (false = medium)
  };

struct SDiag
  {
   int               days;                 // trading days started
   int               levels;               // liquidity levels mapped
   int               barsWatched;          // M1 bars evaluated with active levels
   int               barsTouch;            // ... where price swept a level
   int               signals;              // sweep + M1 confirmation signals
   int               blkFVG;               // signal blocked: no fair value gap
   int               blkTrend;             // signal blocked: H1 bias
   int               blkTime;              // signal blocked: day / hour / closes
   int               blkSession;           // signal blocked: killzone
   int               blkNews;              // signal blocked: news
   int               blkSpread;            // signal blocked: spread
   int               blkVol;               // signal blocked: volatility
   int               skipMaxSL;            // signal skipped: SL above the maximum
   int               skipLots;             // signal skipped: lot / risk / margin
   int               failOrder;            // order rejected
   int               opened;               // setups opened
  };

#define DIAG(f) { g_diag.f++; g_diagD.f++; }

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
const string   g_pfx     = "LSC_";
const string   g_eaName  = "XAU Liquidity Scalper";
const string   g_eaVer   = "1.00";

CTrade         g_tradeP;                   // TP1 / partial trade (magic)
CTrade         g_tradeR;                   // TP2 trade (magic + 1)
SLevel         g_lv[];
SNewsEvent     g_news[];
ulong          g_trailTickets[];
SDiag          g_diag;                     // whole run
SDiag          g_diagD;                    // current day

long           g_magicP            = 0;
long           g_magicR            = 0;
int            g_hAtrM1            = INVALID_HANDLE;
int            g_hAtrM5            = INVALID_HANDLE;
int            g_hAtrM15           = INVALID_HANDLE;
int            g_hAtrTrail         = INVALID_HANDLE;
int            g_hTrendMA          = INVALID_HANDLE;
datetime       g_newsLoaded        = 0;
bool           g_newsCalendarOk    = false;
datetime       g_lastNewsAlert     = 0;
int            g_trendDir          = 0;
datetime       g_curWeekStart      = 0;
datetime       g_dayStart          = 0;
datetime       g_closeEffective    = 0;    // Friday close (server) for this week
datetime       g_lastM1Bar         = 0;
datetime       g_lastH1Bar         = 0;
datetime       g_lastEvalBar       = 0;
datetime       g_lastCloseAttempt  = 0;
datetime       g_lastDayClose      = 0;
datetime       g_lastTargetClose   = 0;
datetime       g_lastTgPoll        = 0;
datetime       g_lastPanelUpdate   = 0;
datetime       g_lastReportedSetup = 0;
bool           g_isTester          = false;
bool           g_visual            = true;
bool           g_drawOn            = true;
bool           g_netting           = false;
bool           g_tgUrlWarned       = false;
bool           g_closeFailNotified = false;
bool           g_targetHit         = false;
double         g_weekRealized      = 0.0;
//--- day state
double         g_dayStartBalance   = 0.0;
double         g_dayRealized       = 0.0;
int            g_daySetups         = 0;
int            g_daySetupsMem      = 0;
int            g_dayConsec         = 0;
datetime       g_dayLastClose      = 0;
bool           g_dayStopped        = false;
int            g_dayStopCode       = 0;
string         g_dayStopReason     = "";
//--- levels
double         g_pdh               = 0.0;
double         g_pdl               = 0.0;
bool           g_pdOk              = false;
double         g_asiaHigh          = 0.0;
double         g_asiaLow           = 0.0;
datetime       g_asiaStartSrv      = 0;
datetime       g_asiaEndSrv        = 0;
bool           g_asiaDone          = false;
//--- telegram / status
long           g_tgOffset          = 0;
string         g_tgToken           = "";
string         g_tgChat            = "";
string         g_status            = "Initialising";
string         g_lastCloseReason   = "";
string         g_lastBlock         = "";

string GVName(const string key)
  {
   return "LSC_" + _Symbol + "_" + IntegerToString(InpMagic) + "_" + key;
  }

//+------------------------------------------------------------------+
//| Shared: Generic helpers                                          |
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

string TFText(const ENUM_TIMEFRAMES tf)
  {
   string s = EnumToString(tf);
   if(StringFind(s, "PERIOD_") == 0)
      s = StringSubstr(s, 7);
   return s;
  }

//--- swing (fractal) points on a series-ordered rates array: k bars on each side
bool IsSwingHigh(const MqlRates &r[], const int j, const int k)
  {
   for(int i = 1; i <= k; i++)
      if(r[j - i].high >= r[j].high || r[j + i].high > r[j].high)
         return false;
   return true;
  }

bool IsSwingLow(const MqlRates &r[], const int j, const int k)
  {
   for(int i = 1; i <= k; i++)
      if(r[j - i].low <= r[j].low || r[j + i].low < r[j].low)
         return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Shared: Time zones, DST, sessions                                |
//+------------------------------------------------------------------+
datetime MakeDate(const int y, const int m, const int d, const int h, const int mi)
  {
   MqlDateTime s;
   ZeroMemory(s);
   s.year = y;
   s.mon  = m;
   s.day  = d;
   s.hour = h;
   s.min  = mi;
   s.sec  = 0;
   return StructToTime(s);
  }

//--- n >= 1: n-th Sunday of the month, n <= 0: last Sunday of the month (00:00)
datetime NthSunday(const int y, const int m, const int n)
  {
   if(n >= 1)
     {
      int dow = DowOf(MakeDate(y, m, 1, 0, 0));
      return MakeDate(y, m, 1 + (7 - dow) % 7 + (n - 1) * 7, 0, 0);
     }
   int ny = (m == 12) ? y + 1 : y;
   int nm = (m == 12) ? 1 : m + 1;
   datetime last = (datetime)((long)MakeDate(ny, nm, 1, 0, 0) - 86400);
   return (datetime)((long)last - (long)DowOf(last) * 86400);
  }

//--- US summer time: 2nd Sunday of March 02:00 EST -> 1st Sunday of November 02:00 EDT
bool IsUSDST(const datetime gmt)
  {
   MqlDateTime d;
   TimeToStruct(gmt, d);
   long start = (long)NthSunday(d.year, 3, 2) + 7 * 3600;
   long end   = (long)NthSunday(d.year, 11, 1) + 6 * 3600;
   return ((long)gmt >= start && (long)gmt < end);
  }

//--- UK summer time: last Sunday of March 01:00 GMT -> last Sunday of October 01:00 GMT
bool IsUKDST(const datetime gmt)
  {
   MqlDateTime d;
   TimeToStruct(gmt, d);
   long start = (long)NthSunday(d.year, 3, 0) + 3600;
   long end   = (long)NthSunday(d.year, 10, 0) + 3600;
   return ((long)gmt >= start && (long)gmt < end);
  }

//--- broker server offset from GMT (seconds). Live: measured. Tester: inputs (+ US DST rule).
int BrokerOffsetAt(const datetime serverTime)
  {
   if(!g_isTester)
     {
      long diff = (long)TimeTradeServer() - (long)TimeGMT();
      return (int)(MathRound((double)diff / 900.0) * 900.0);
     }
   int off = (int)MathRound(InpTesterBrokerGMT * 3600.0);
   if(InpTesterUSDST && IsUSDST((datetime)((long)serverTime - off)))
      off += 3600;
   return off;
  }

datetime ServerToGMT(const datetime serverTime)
  {
   return (datetime)((long)serverTime - BrokerOffsetAt(serverTime));
  }

datetime GMTToServer(const datetime gmt)
  {
   int off = BrokerOffsetAt((datetime)((long)gmt + (long)MathRound(InpTesterBrokerGMT * 3600.0)));
   return (datetime)((long)gmt + off);
  }

bool InHourWindow(const datetime localTime, const int startH, const int endH)
  {
   int m = MinuteOfDay(localTime);
   int s = startH * 60, e = endH * 60;
   if(s == e)
      return true;
   if(s < e)
      return (m >= s && m < e);
   return (m >= s || m < e);                 // window crosses midnight
  }

bool SessionAllows(const datetime serverNow, string &label)
  {
   datetime gmt = ServerToGMT(serverNow);
   bool ok = false;
   label = "";
   if(InpSessLondon)
     {
      datetime lon = (datetime)((long)gmt + (IsUKDST(gmt) ? 3600 : 0));
      if(InHourWindow(lon, InpLondonStartHour, InpLondonEndHour))
        {
         ok = true;
         label = "London";
        }
     }
   if(InpSessNewYork)
     {
      datetime nyc = (datetime)((long)gmt - 5 * 3600 + (IsUSDST(gmt) ? 3600 : 0));
      if(InHourWindow(nyc, InpNYStartHour, InpNYEndHour))
        {
         ok = true;
         label = (label == "") ? "New York" : label + " + New York";
        }
     }
   if(InpSessAsia)
     {
      datetime tky = (datetime)((long)gmt + 9 * 3600);
      if(InHourWindow(tky, InpAsiaStartHour, InpAsiaEndHour))
        {
         ok = true;
         label = (label == "") ? "Asia" : label + " + Asia";
        }
     }
   if(!InpUseSessionFilter)
     {
      label = (label == "") ? "filter off" : label + " (filter off)";
      return true;
     }
   if(!ok)
      label = "closed (outside the selected sessions)";
   return ok;
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

//+------------------------------------------------------------------+
//| Shared: High-impact news filter                                  |
//+------------------------------------------------------------------+
void PushNews(const datetime t, const string name, const string cur, const bool high)
  {
   int n = ArraySize(g_news);
   ArrayResize(g_news, n + 1);
   g_news[n].time     = t;
   g_news[n].name     = name;
   g_news[n].currency = cur;
   g_news[n].high     = high;
  }

bool NewsKeywordMatch(const string eventName)
  {
   string kw = InpNewsKeywords;
   StringTrimLeft(kw);
   StringTrimRight(kw);
   if(kw == "")
      return true;
   string name = eventName;
   StringToLower(name);
   string parts[];
   int n = StringSplit(kw, ',', parts);
   for(int i = 0; i < n; i++)
     {
      string p = parts[i];
      StringTrimLeft(p);
      StringTrimRight(p);
      StringToLower(p);
      if(p != "" && StringFind(name, p) >= 0)
         return true;
     }
   return false;
  }

//--- MT5 economic calendar (live terminal only - not available in the Strategy Tester)
bool LoadCalendarNews(const datetime now)
  {
   string cur[];
   int nc = StringSplit(InpNewsCurrencies, ',', cur);
   if(nc <= 0)
      return false;
   datetime from = (datetime)((long)now - 86400);
   datetime to   = (datetime)((long)now + 8 * 86400);
   int total = 0;
   for(int c = 0; c < nc; c++)
     {
      string code = cur[c];
      StringTrimLeft(code);
      StringTrimRight(code);
      StringToUpper(code);
      if(code == "")
         continue;
      MqlCalendarValue vals[];
      ResetLastError();
      CalendarValueHistory(vals, from, to, NULL, code);
      if(GetLastError() != 0)
         continue;
      int n = ArraySize(vals);
      total += n;
      for(int i = 0; i < n; i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(vals[i].event_id, ev))
            continue;
         if(ev.time_mode != CALENDAR_TIMEMODE_DATETIME)
            continue;
         bool high = (ev.importance == CALENDAR_IMPORTANCE_HIGH);
         bool med  = (ev.importance == CALENDAR_IMPORTANCE_MODERATE);
         if(!high && !(InpNewsIncludeMedium && med))
            continue;
         if(!NewsKeywordMatch(ev.name))
            continue;
         PushNews(vals[i].time, ev.name, code, high);
        }
     }
   return (total > 0);                       // an empty calendar = not synchronised yet
  }

//--- Non-Farm Payrolls: first Friday of the month, 08:30 New York time
void AddNFPRule(const datetime now)
  {
   MqlDateTime d;
   TimeToStruct(now, d);
   for(int k = -1; k <= 1; k++)
     {
      int m = d.mon + k, y = d.year;
      if(m < 1)
        {
         m += 12;
         y--;
        }
      if(m > 12)
        {
         m -= 12;
         y++;
        }
      int dow = DowOf(MakeDate(y, m, 1, 0, 0));
      int day = 1 + (5 - dow + 7) % 7;
      datetime gmt = MakeDate(y, m, day, 13, 30);              // 08:30 EST = 13:30 GMT
      if(IsUSDST(gmt))
         gmt = (datetime)((long)gmt - 3600);                  // 08:30 EDT = 12:30 GMT
      PushNews(GMTToServer(gmt), "Non-Farm Payrolls (rule)", "USD", true);
     }
  }

void AddManualNews(void)
  {
   string s = InpNewsManualTimes;
   StringTrimLeft(s);
   StringTrimRight(s);
   if(s == "")
      return;
   string parts[];
   int n = StringSplit(s, ';', parts);
   for(int i = 0; i < n; i++)
     {
      string p = parts[i];
      StringTrimLeft(p);
      StringTrimRight(p);
      if(p == "")
         continue;
      datetime t = StringToTime(p);
      if(t > 0)
         PushNews(t, "Manual news", "", true);
     }
  }

void RefreshNews(const datetime now)
  {
   if(!InpUseNewsFilter)
      return;
   long every = (!g_isTester && !g_newsCalendarOk) ? 300 : 3600;   // retry quickly while the calendar is not ready
   if(g_newsLoaded > 0 && (long)now >= (long)g_newsLoaded && (long)now - (long)g_newsLoaded < every)
      return;
   g_newsLoaded = now;
   ArrayResize(g_news, 0);
   AddManualNews();
   g_newsCalendarOk = (!g_isTester && LoadCalendarNews(now));
   if(!g_newsCalendarOk && InpNewsNFPRule)
      AddNFPRule(now);
  }

//--- index of the news event that blocks entries at 'now', -1 if none
int BlockingNews(const datetime now)
  {
   if(!InpUseNewsFilter)
      return -1;
   for(int i = 0; i < ArraySize(g_news); i++)
     {
      long t = (long)g_news[i].time;
      if((long)now >= t - (long)InpNewsMinsBefore * 60 && (long)now <= t + (long)InpNewsMinsAfter * 60)
         return i;
     }
   return -1;
  }

string NewsLine(const int i)
  {
   string imp = g_news[i].high ? "HIGH" : "MED";
   string cur = (g_news[i].currency == "") ? "" : g_news[i].currency + " ";
   return DayTime(g_news[i].time) + "  " + cur + g_news[i].name + " [" + imp + "]";
  }

string UpcomingNewsText(const datetime now, const int hours)
  {
   string s = "";
   int cnt = 0;
   for(int i = 0; i < ArraySize(g_news); i++)
     {
      long t = (long)g_news[i].time;
      if(t >= (long)now - (long)InpNewsMinsAfter * 60 && t <= (long)now + (long)hours * 3600)
        {
         s += " - " + NewsLine(i) + "\n";
         cnt++;
        }
     }
   if(cnt == 0)
      s = " - none\n";
   return s;
  }

string NewsSourceText(void)
  {
   if(!InpUseNewsFilter)
      return "off";
   if(g_newsCalendarOk)
      return "MT5 economic calendar";
   return InpNewsNFPRule ? "NFP rule + manual list (no calendar)" : "manual list (no calendar)";
  }

//+------------------------------------------------------------------+
//| Shared: HTF bias (trend) filter                                  |
//+------------------------------------------------------------------+
int MATrend(void)
  {
   if(g_hTrendMA == INVALID_HANDLE)
      return 0;
   int slope = (InpTrendSlopeBars > 0) ? InpTrendSlopeBars : 0;
   int need  = slope + 1;
   double ma[];
   ArraySetAsSeries(ma, true);
   if(CopyBuffer(g_hTrendMA, 0, 1, need, ma) < need)
      return 0;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpTrendTF, 1, 1, r) < 1)
      return 0;
   double c = r[0].close;
   bool slopeUp = (slope == 0) || (ma[0] > ma[slope]);
   bool slopeDn = (slope == 0) || (ma[0] < ma[slope]);
   if(c > ma[0] && slopeUp)
      return 1;
   if(c < ma[0] && slopeDn)
      return -1;
   return 0;
  }

int StructureTrend(void)
  {
   int k = (InpTrendSwingBars > 0) ? InpTrendSwingBars : 1;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int n = CopyRates(_Symbol, InpTrendTF, 0, InpTrendLookback, r);
   if(n < 2 * k + 6)
      return 0;
   double h1 = 0, h2 = 0, l1 = 0, l2 = 0;
   int nh = 0, nl = 0;
   for(int j = k + 1; j < n - k && (nh < 2 || nl < 2); j++)
     {
      if(nh < 2 && IsSwingHigh(r, j, k))
        {
         if(nh == 0)
            h1 = r[j].high;
         else
            h2 = r[j].high;
         nh++;
        }
      if(nl < 2 && IsSwingLow(r, j, k))
        {
         if(nl == 0)
            l1 = r[j].low;
         else
            l2 = r[j].low;
         nl++;
        }
     }
   if(nh < 1 || nl < 1)
      return 0;
   if(r[1].close > h1)                       // bullish break of structure
      return 1;
   if(r[1].close < l1)                       // bearish break of structure
      return -1;
   if(nh < 2 || nl < 2)
      return 0;
   if(h1 > h2 && l1 > l2)                    // higher high + higher low
      return 1;
   if(h1 < h2 && l1 < l2)                    // lower high + lower low
      return -1;
   return 0;
  }

int TrendDir(void)
  {
   if(InpTrendMode == TREND_OFF)
      return 0;
   if(InpTrendMode == TREND_MA)
      return MATrend();
   if(InpTrendMode == TREND_STRUCTURE)
      return StructureTrend();
   int a = MATrend();
   int b = StructureTrend();
   return (a == b) ? a : 0;
  }

bool TrendAllows(const int dir, const int trend)
  {
   if(InpTrendMode == TREND_OFF)
      return true;
   if(trend == 0)
      return !InpTrendBlockNeutral;
   return (trend == dir);
  }

string TrendText(const int trend)
  {
   if(InpTrendMode == TREND_OFF)
      return "filter off";
   string tf = TFText(InpTrendTF);
   if(trend > 0)
      return tf + " UP (buys only)";
   if(trend < 0)
      return tf + " DOWN (sells only)";
   return tf + " NEUTRAL" + (InpTrendBlockNeutral ? " (no trades)" : " (both sides)");
  }

//+------------------------------------------------------------------+
//| Shared: Positions / history                                      |
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

void UpdateWeekRealized(void)
  {
   SStats s;
   CalcStats(g_curWeekStart, (datetime)((long)TimeCurrent() + 86400), s);
   g_weekRealized = s.net;
  }

double WeekProgress(void)
  {
   return g_weekRealized + (InpTargetIncludeFloating ? FloatingPL() : 0.0);
  }

string TargetText(void)
  {
   if(InpWeeklyProfitTarget <= 0)
      return "off";
   string s = SignedMoney(WeekProgress()) + " / " + M2S(InpWeeklyProfitTarget) + " " + Currency();
   if(g_targetHit)
      s += " - REACHED";
   return s;
  }

void CheckWeeklyTarget(void)
  {
   if(InpWeeklyProfitTarget <= 0 || g_curWeekStart == 0)
      return;
   if(!g_targetHit)
     {
      double progress = WeekProgress();
      if(progress < InpWeeklyProfitTarget)
         return;
      g_targetHit = true;
      GlobalVariableSet(GVName("target"), (double)g_curWeekStart);
      int nP0 = 0, nR0 = 0;
      int open = CountOurPositions(nP0, nR0);
      string act = (open > 0 && InpTargetCloseTrades) ? "Closing the open trade(s) to lock the profit.\n" : "";
      TgSend(E_Target() + " WEEKLY PROFIT TARGET REACHED - " + _Symbol + "\n"
             + "Week result: " + SignedMoney(progress) + " " + Currency() + " (target " + M2S(InpWeeklyProfitTarget) + ")\n"
             + act + "No new trades until next week.");
      g_status = "Weekly profit target reached - no new trades this week";
     }
   if(!InpTargetCloseTrades)
      return;
   int nP = 0, nR = 0;
   if(CountOurPositions(nP, nR) == 0)
      return;
   datetime now = TimeCurrent();
   long since = (long)now - (long)g_lastTargetClose;
   if(g_lastTargetClose > 0 && since >= 0 && since < 15)
      return;
   g_lastTargetClose = now;
   CloseAllOurPositions("WEEKLY PROFIT TARGET REACHED");
  }

//+------------------------------------------------------------------+
//| Shared: Signal building blocks (rejection candle, ChoCH)         |
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

bool CheckChoch(const SOrderBlock &ob, const MqlRates &m5[], const int count, const double atr, const int late,
                string &pattern, double &sweepExt, double &level, int &breakBar)
  {
   int k = (InpChochSwingBars > 0) ? InpChochSwingBars : 1;
   int maxW = InpChochWindow;
   if(maxW > count - InpChochSwingLookback - k - 3)
      maxW = count - InpChochSwingLookback - k - 3;
   if(maxW < 1)
      return false;
   bool isSell = (ob.dir < 0);

   //--- 1. the tap: most extreme M5 candle inside the OB within the window
   int p = -1;
   for(int s = 1; s <= maxW; s++)
     {
      if(!(m5[s].high >= ob.low && m5[s].low <= ob.high))
         continue;
      if(p < 0 || (isSell && m5[s].high > m5[p].high) || (!isSell && m5[s].low < m5[p].low))
         p = s;
     }
   if(p < 0)
      return false;

   //--- 2. the swing that must break: last swing low (sell) / high (buy) formed before the tap
   bool found = false;
   int jStart = (p + 1 > k + 1) ? p + 1 : k + 1;
   for(int j = jStart; j <= p + InpChochSwingLookback && j + k < count; j++)
     {
      if(isSell && IsSwingLow(m5, j, k))
        {
         level = m5[j].low;
         found = true;
         break;
        }
      if(!isSell && IsSwingHigh(m5, j, k))
        {
         level = m5[j].high;
         found = true;
         break;
        }
     }
   if(!found)
      return false;

   //--- 3. the break: first candle after the tap that closes beyond the swing. It must be one of the
   //---    candles closed since the previous check ('late', normally 1) and price must still be beyond it
   int b = -1;
   for(int s2 = p; s2 >= 1; s2--)
      if(isSell ? (m5[s2].close < level) : (m5[s2].close > level))
        {
         b = s2;
         break;
        }
   if(b < 0 || b > late)
      return false;                          // no break yet, or it was already evaluated earlier
   if(isSell ? !(m5[1].close < level) : !(m5[1].close > level))
      return false;                          // price is back on the wrong side of the swing
   breakBar = b;

   sweepExt = isSell ? m5[p].high : m5[p].low;
   string side = isSell ? "below swing low " : "above swing high ";
   pattern  = "ChoCH: M1 close " + side + P2S(level) + " after the sweep to " + P2S(sweepExt);

   //--- 4. optional: a rejection candle between the tap and the break
   if(InpEntryConfirm == CONFIRM_REJECTION_CHOCH)
     {
      bool rej = false;
      string rp = "";
      for(int s3 = 1; s3 <= p && !rej; s3++)
         rej = IsRejection(ob, m5, s3, atr, rp);
      if(!rej)
         return false;
      pattern = rp + " + " + pattern;
     }
   return true;
  }

void PushPOI(SOrderBlock &arr[], int &src[], const SOrderBlock &p, const int from)
  {
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   ArrayResize(src, n + 1);
   arr[n] = p;
   src[n] = from;
  }

void LogSignal(const string tag, const string reason)
  {
   g_lastBlock = reason;
   if(InpLogSignals)
      Print("SIGNAL ", tag, " -> NOT TAKEN: ", reason);
  }

//+------------------------------------------------------------------+
//| Shared: Order sending + trade management                         |
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
      err = "2 x minimum lot risks " + M2S(riskMoney) + " " + Currency() + " = above the max "
            + DoubleToString(InpMaxRiskPercent, 1) + "% of balance (deposit too small for this SL - raise the deposit, 'Max risk %' or use fixed lots)";
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

string TrailText(void)
  {
   return TFText(InpTrailTF) + " ATR(" + IntegerToString(InpTrailATRPeriod) + ") x " + DoubleToString(InpTrailATRMult, 1);
  }

string TP2ModeText(void)
  {
   if(InpTP2Mode == TP2_FIXED_RR)
      return "1:" + DoubleToString(InpRewardRisk, 1);
   if(InpTP2Mode == TP2_ATR_TRAIL)
      return "ATR trail (" + TrailText() + ")";
   return "1:" + DoubleToString(InpRewardRisk, 1) + " + ATR trail (" + TrailText() + ")";
  }

string SessionSetupText(void)
  {
   if(!InpUseSessionFilter)
      return "off";
   string s = "";
   if(InpSessLondon)
      s += "London " + IntegerToString(InpLondonStartHour) + "-" + IntegerToString(InpLondonEndHour) + " ";
   if(InpSessNewYork)
      s += "NY " + IntegerToString(InpNYStartHour) + "-" + IntegerToString(InpNYEndHour) + " ";
   if(InpSessAsia)
      s += "Tokyo " + IntegerToString(InpAsiaStartHour) + "-" + IntegerToString(InpAsiaEndHour) + " ";
   return s + "(local)";
  }

string FiltersStatusText(const datetime now)
  {
   string sess = "";
   bool sOk = SessionAllows(now, sess);
   int ni = BlockingNews(now);
   string news = (!InpUseNewsFilter) ? "off" : (ni >= 0 ? "PAUSED - " + g_news[ni].name + " " + TimeToString(g_news[ni].time, TIME_MINUTES) : "clear");
   string state = sOk ? "OPEN " : "CLOSED ";
   return "Session: " + state + sess + "\n"
          + "News: " + news + " (" + NewsSourceText() + ")\n"
          + "HTF trend: " + TrendText(TrendDir()) + "\n";
  }

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

bool TrailActive(const ulong ticket)
  {
   for(int i = 0; i < ArraySize(g_trailTickets); i++)
      if(g_trailTickets[i] == ticket)
         return true;
   return false;
  }

void ActivateTrail(const ulong ticket)
  {
   if(InpTP2Mode == TP2_FIXED_RR || TrailActive(ticket))
      return;
   int n = ArraySize(g_trailTickets);
   ArrayResize(g_trailTickets, n + 1);
   g_trailTickets[n] = ticket;
   double atr = GetATR(g_hAtrTrail, 1);
   TgSend(E_Shield() + " " + _Symbol + " TP1 done - ATR TRAILING STOP ACTIVE on the TP2 trade\n"
          + "Trail: " + TrailText() + " = " + P2S(InpTrailATRMult * atr) + " behind price, step " + P2S(InpTrailStep));
  }

//--- trail one position: SL = price -/+ ATR x mult, never worse than breakeven (if enabled), only improves
void TrailPosition(CTrade &t, const ulong ticket, const double dist, const MqlTick &tick, const double minDist)
  {
   if(!PositionSelectByTicket(ticket))
      return;
   bool isSell = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL);
   double open = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl   = PositionGetDouble(POSITION_SL);
   double tp   = PositionGetDouble(POSITION_TP);
   double cand = isSell ? tick.ask + dist : tick.bid - dist;
   if(InpMoveRunnerToBE)
     {
      double be = isSell ? open - InpBEOffset : open + InpBEOffset;
      cand = isSell ? MathMin(cand, be) : MathMax(cand, be);
     }
   cand = NormPrice(cand);
   bool improves = isSell ? (sl <= 0 || cand <= sl - InpTrailStep) : (cand >= sl + InpTrailStep);
   if(!improves)
      return;
   if(isSell ? (cand <= tick.ask + minDist) : (cand >= tick.bid - minDist))
      return;                                // too close to the market for the broker
   if(!t.PositionModify(ticket, cand, tp))
     {
      Print("Trailing modify failed #", ticket, ": ", t.ResultRetcodeDescription());
      return;
     }
   if(InpTgNotifyTrail)
      TgSend(E_Shield() + " " + _Symbol + " trailing stop moved: SL " + P2S(cand)
             + " (locked " + P2S(isSell ? open - cand : cand - open) + " from entry)");
  }

void ManageTrailing(void)
  {
   if(InpTP2Mode == TP2_FIXED_RR)
      return;
   ulong list[];
   if(g_netting)
     {
      string gDone = GVName("vtp1done");
      if(!GlobalVariableCheck(gDone) || GlobalVariableGet(gDone) < 0.5)
         return;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong tk = PositionGetTicket(i);
         if(tk == 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == g_magicP)
           {
            ArrayResize(list, 1);
            list[0] = tk;
            break;
           }
        }
     }
   else
     {
      //--- keep only runners that are still open
      ulong keep[];
      for(int i = 0; i < ArraySize(g_trailTickets); i++)
         if(PositionSelectByTicket(g_trailTickets[i]))
           {
            int n = ArraySize(keep);
            ArrayResize(keep, n + 1);
            keep[n] = g_trailTickets[i];
           }
      ArrayResize(g_trailTickets, ArraySize(keep));
      for(int i2 = 0; i2 < ArraySize(keep); i2++)
        {
         g_trailTickets[i2] = keep[i2];
         ArrayResize(list, i2 + 1);
         list[i2] = keep[i2];
        }
     }
   if(ArraySize(list) == 0)
      return;
   double atr = GetATR(g_hAtrTrail, 1);
   if(atr <= 0)
      return;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;
   double dist    = InpTrailATRMult * atr;
   double minDist = StopsDistance();
   for(int j = 0; j < ArraySize(list); j++)
     {
      if(g_netting)
         TrailPosition(g_tradeP, list[j], dist, tick, minDist);
      else
         TrailPosition(g_tradeR, list[j], dist, tick, minDist);
     }
  }

//--- after TP1: breakeven and / or ATR trailing for the TP2 trade (hedging accounts)
void ManageRunners(void)
  {
   bool trail = (InpTP2Mode != TP2_FIXED_RR);
   if((!InpMoveRunnerToBE && !trail) || g_netting)
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
     {
      if(!TrailActive(tickets[j]) && !PartialTPHitSince((datetime)times[j]))
         continue;
      if(InpMoveRunnerToBE)
         MoveToBreakeven(g_tradeR, tickets[j]);
      if(trail)
         ActivateTrail(tickets[j]);
     }
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
      if(InpTP2Mode != TP2_FIXED_RR)
         TgSend(E_Shield() + " " + _Symbol + " TP1 done - ATR TRAILING STOP ACTIVE on the remaining volume (" + TrailText() + ")");
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

//+------------------------------------------------------------------+
//| Shared: Chart drawing                                            |
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

//+------------------------------------------------------------------+
//| Shared: Telegram                                                 |
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

string BuildNewsText(void)
  {
   datetime now = ServerNow();
   RefreshNews(now);
   string s = E_Warn() + " HIGH-IMPACT NEWS - next 48h (server time)\n";
   if(!InpUseNewsFilter)
      return s + "News filter is OFF.";
   s += "Source: " + NewsSourceText() + " | currencies " + InpNewsCurrencies + "\n";
   s += "Entries paused " + IntegerToString(InpNewsMinsBefore) + " min before / " + IntegerToString(InpNewsMinsAfter) + " min after\n";
   s += UpcomingNewsText(now, 48);
   int ni = BlockingNews(now);
   if(ni >= 0)
      s += "NOW PAUSED: " + g_news[ni].name;
   return s;
  }

//+------------------------------------------------------------------+
//| Scalper: liquidity levels                                        |
//+------------------------------------------------------------------+
string LevelName(const SLevel &lv)
  {
   if(lv.kind == 0)
      return (lv.side > 0) ? "PDH" : "PDL";
   string hl = (lv.side > 0) ? "high" : "low";
   if(lv.kind == 1)
      return "Asian " + hl;
   return "H1 swing " + hl;
  }

void AddLevel(SLevel &arr[], const double price, const int side, const int kind, const datetime t, const double mergeDist)
  {
   for(int i = 0; i < ArraySize(arr); i++)
      if(arr[i].side == side && MathAbs(arr[i].price - price) <= mergeDist)
         return;                             // already covered by a stronger level
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n].price  = price;
   arr[n].side   = side;
   arr[n].kind   = kind;
   arr[n].time   = t;
   arr[n].broken = false;
   arr[n].used   = false;
  }

int ActiveLevelCount(const int side)
  {
   int c = 0;
   for(int i = 0; i < ArraySize(g_lv); i++)
      if(g_lv[i].side == side && !g_lv[i].broken && !g_lv[i].used)
         c++;
   return c;
  }

void RebuildLevels(const datetime now)
  {
   if(g_dayStart == 0)
      return;
   double atr5  = GetATR(g_hAtrM5, 1);
   double merge = (atr5 > 0) ? 0.25 * atr5 : 0.50;
   SLevel nl[];

   //--- previous day high / low (last completed weekday D1 candle)
   g_pdOk = false;
   if(InpLiqPrevDay)
     {
      MqlRates d1[];
      ArraySetAsSeries(d1, true);
      int n = CopyRates(_Symbol, PERIOD_D1, 1, 4, d1);
      for(int i = 0; i < n; i++)
        {
         int dow = DowOf(d1[i].time);
         if(dow == 0 || dow == 6)
            continue;
         g_pdh  = d1[i].high;
         g_pdl  = d1[i].low;
         g_pdOk = true;
         AddLevel(nl, g_pdh, +1, 0, d1[i].time, merge);
         AddLevel(nl, g_pdl, -1, 0, d1[i].time, merge);
         break;
        }
     }

   //--- Asian range of the current GMT day (only once the range is complete)
   g_asiaDone = false;
   if(InpLiqAsia)
     {
      datetime gmtNow = ServerToGMT(now);
      datetime gday   = DayStart(gmtNow);
      datetime aS     = (datetime)((long)gday + (long)InpAsiaRangeStartGMT * 3600);
      datetime aE     = (datetime)((long)gday + (long)InpAsiaRangeEndGMT * 3600);
      g_asiaStartSrv  = GMTToServer(aS);
      g_asiaEndSrv    = GMTToServer(aE);
      if(gmtNow >= aE)
        {
         MqlRates r[];
         int n = CopyRates(_Symbol, PERIOD_M5, g_asiaStartSrv, (datetime)((long)g_asiaEndSrv - 1), r);
         if(n >= 6)
           {
            double hi = -DBL_MAX, lo = DBL_MAX;
            for(int i = 0; i < n; i++)
              {
               if(r[i].high > hi)
                  hi = r[i].high;
               if(r[i].low < lo)
                  lo = r[i].low;
              }
            g_asiaHigh = hi;
            g_asiaLow  = lo;
            g_asiaDone = true;
            AddLevel(nl, hi, +1, 1, g_asiaEndSrv, merge);
            AddLevel(nl, lo, -1, 1, g_asiaEndSrv, merge);
           }
        }
     }

   //--- unswept H1 swing highs / lows (a sweep by the last closed H1 bar still counts as "fresh")
   if(InpLiqH1Swings)
     {
      int k = (InpH1SwingStrength > 0) ? InpH1SwingStrength : 1;
      MqlRates h1[];
      ArraySetAsSeries(h1, true);
      int n = CopyRates(_Symbol, PERIOD_H1, 0, InpH1SwingLookback + k + 2, h1);
      for(int j = k + 1; j < n - k; j++)
        {
         if(IsSwingHigh(h1, j, k))
           {
            bool taken = false;
            for(int i = j - 1; i >= 2 && !taken; i--)
               if(h1[i].high > h1[j].high)
                  taken = true;
            if(!taken)
               AddLevel(nl, h1[j].high, +1, 2, h1[j].time, merge);
           }
         if(IsSwingLow(h1, j, k))
           {
            bool taken = false;
            for(int i = j - 1; i >= 2 && !taken; i--)
               if(h1[i].low < h1[j].low)
                  taken = true;
            if(!taken)
               AddLevel(nl, h1[j].low, -1, 2, h1[j].time, merge);
           }
        }
     }

   //--- keep the broken / used state of levels that already existed
   int fresh = 0;
   for(int i = 0; i < ArraySize(nl); i++)
     {
      bool found = false;
      for(int o = 0; o < ArraySize(g_lv); o++)
         if(g_lv[o].kind == nl[i].kind && g_lv[o].side == nl[i].side && MathAbs(g_lv[o].price - nl[i].price) < _Point * 0.5)
           {
            nl[i].broken = g_lv[o].broken;
            nl[i].used   = g_lv[o].used;
            found = true;
            break;
           }
      if(!found)
         fresh++;
     }
   ArrayResize(g_lv, ArraySize(nl));
   for(int i = 0; i < ArraySize(nl); i++)
      g_lv[i] = nl[i];
   g_diag.levels  += fresh;
   g_diagD.levels += fresh;
   DrawLevels();
  }

void DrawLevels(void)
  {
   if(!g_drawOn || g_dayStart == 0)
      return;
   datetime tEnd = (datetime)((long)g_dayStart + (long)InpDailyCloseHour * 3600 + (long)InpDailyCloseMinute * 60);
   if(g_asiaDone)
     {
      string an = g_pfx + "ASIA_" + IntegerToString((long)g_asiaStartSrv);
      DrawRect(an, g_asiaStartSrv, g_asiaHigh, g_asiaEndSrv, g_asiaLow, InpAsiaColor, true, 1, STYLE_SOLID, true);
      DrawLabel(an + "_T", g_asiaStartSrv, g_asiaHigh, "ASIAN RANGE " + P2S(g_asiaLow) + " - " + P2S(g_asiaHigh), clrSilver, ANCHOR_LEFT_LOWER);
     }
   for(int i = 0; i < ArraySize(g_lv); i++)
     {
      string nm = g_pfx + "LV_" + IntegerToString(g_lv[i].kind) + "_" + IntegerToString(g_lv[i].side) + "_" + IntegerToString((long)g_lv[i].time);
      color c = (g_lv[i].side > 0) ? InpLevelHighColor : InpLevelLowColor;
      string st = "";
      if(g_lv[i].broken)
        {
         c  = clrDimGray;
         st = " (broken)";
        }
      else
         if(g_lv[i].used)
           {
            c  = clrSlateGray;
            st = " (traded)";
           }
      datetime t0 = (g_lv[i].kind == 0) ? g_dayStart : g_lv[i].time;
      ENUM_LINE_STYLE ls = (g_lv[i].kind == 2) ? STYLE_DOT : STYLE_DASH;
      int w = (g_lv[i].kind == 2) ? 1 : 2;
      DrawSeg(nm, t0, g_lv[i].price, tEnd, g_lv[i].price, c, w, ls);
      DrawLabel(nm + "_T", t0, g_lv[i].price, LevelName(g_lv[i]) + " " + P2S(g_lv[i].price) + st, c,
                (g_lv[i].side > 0) ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER);
     }
   ChartRedraw(0);
  }

string LevelsText(void)
  {
   string s = "";
   if(g_pdOk)
      s += "PDH " + P2S(g_pdh) + " | PDL " + P2S(g_pdl) + "\n";
   if(g_asiaDone)
      s += "Asian range " + P2S(g_asiaLow) + " - " + P2S(g_asiaHigh) + "\n";
   else
      if(InpLiqAsia)
         s += "Asian range: forming (complete at " + TimeToString(g_asiaEndSrv, TIME_MINUTES) + " server)\n";
   if(ArraySize(g_lv) == 0)
      return s + "No liquidity levels yet\n";
   for(int i = 0; i < ArraySize(g_lv); i++)
     {
      string st = g_lv[i].broken ? "broken" : (g_lv[i].used ? "traded" : "active");
      s += " - " + LevelName(g_lv[i]) + " " + P2S(g_lv[i].price) + " [" + st + "]\n";
     }
   return s;
  }

//+------------------------------------------------------------------+
//| Scalper: day / week state                                        |
//+------------------------------------------------------------------+
bool TradeDayOk(const int dow)
  {
   return (dow == 1 && InpTradeMonday) || (dow == 2 && InpTradeTuesday) || (dow == 3 && InpTradeWednesday)
          || (dow == 4 && InpTradeThursday) || (dow == 5 && InpTradeFriday);
  }

//--- today's setups, realised P/L, last close time and losing setups in a row - all from the trade history
void UpdateDayStats(void)
  {
   g_daySetups    = 0;
   g_dayRealized  = 0.0;
   g_dayLastClose = 0;
   g_dayConsec    = 0;
   if(g_dayStart == 0)
      return;
   if(!HistorySelect(g_dayStart, (datetime)((long)TimeCurrent() + 86400)))
      return;
   long   setupKey[];
   double setupPL[];
   bool   setupOpen[];
   long   posIds[];
   int    posSetup[];
   int total = HistoryDealsTotal();
   //--- pass 1: entry deals -> setups (the 2 trades of a setup open within a few seconds)
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol || !IsOurMagic(HistoryDealGetInteger(d, DEAL_MAGIC)))
         continue;
      if(HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;
      long t = HistoryDealGetInteger(d, DEAL_TIME);
      int si = -1;
      for(int k = 0; k < ArraySize(setupKey); k++)
         if(t - setupKey[k] <= 10 && setupKey[k] - t <= 10)
           {
            si = k;
            break;
           }
      if(si < 0)
        {
         si = ArraySize(setupKey);
         ArrayResize(setupKey, si + 1);
         ArrayResize(setupPL, si + 1);
         ArrayResize(setupOpen, si + 1);
         setupKey[si]  = t;
         setupPL[si]   = 0.0;
         setupOpen[si] = false;
        }
      double costs = HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
      setupPL[si]   += costs;
      g_dayRealized += costs;
      int np = ArraySize(posIds);
      ArrayResize(posIds, np + 1);
      ArrayResize(posSetup, np + 1);
      posIds[np]   = HistoryDealGetInteger(d, DEAL_POSITION_ID);
      posSetup[np] = si;
     }
   //--- pass 2: exit deals
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol || !IsOurMagic(HistoryDealGetInteger(d, DEAL_MAGIC)))
         continue;
      long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
         continue;
      double pr = HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP)
                  + HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
      g_dayRealized += pr;
      datetime t = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
      if(t > g_dayLastClose)
         g_dayLastClose = t;
      long pid = HistoryDealGetInteger(d, DEAL_POSITION_ID);
      for(int k = 0; k < ArraySize(posIds); k++)
         if(posIds[k] == pid)
           {
            setupPL[posSetup[k]] += pr;
            break;
           }
     }
   //--- setups that still have an open trade
   for(int k = 0; k < ArraySize(posIds); k++)
      if(PositionOpenById(posIds[k]))
         setupOpen[posSetup[k]] = true;
   g_daySetups = ArraySize(setupKey);
   //--- losing setups in a row (most recent closed setups)
   for(int k = ArraySize(setupKey) - 1; k >= 0; k--)
     {
      if(setupOpen[k])
         continue;
      if(setupPL[k] < 0)
         g_dayConsec++;
      else
         break;
     }
  }

void EnsureWeek(const datetime now)
  {
   if((long)now < 946684800)
      return;
   datetime ws = WeekStartOf(now);
   if(ws <= g_curWeekStart)
      return;
   g_curWeekStart      = ws;
   g_closeFailNotified = false;
   g_closeEffective    = (datetime)((long)FridayMarketClose(ws) - (long)InpCloseBeforeMarketMin * 60);
   string gv = GVName("target");
   g_targetHit = GlobalVariableCheck(gv) && (long)GlobalVariableGet(gv) >= (long)ws;
   UpdateWeekRealized();
  }

string DayStopText(const int code)
  {
   if(code == 1)
      return "Daily loss limit reached";
   if(code == 2)
      return "Daily profit target reached";
   if(code == 3)
      return IntegerToString(InpMaxConsecLosses) + " losing setups in a row";
   return "Daily stop";
  }

void EnsureDay(const datetime now)
  {
   if((long)now < 946684800)
      return;
   datetime d = DayStart(now);
   if(d <= g_dayStart)
      return;
   if(g_dayStart > 0)
      PrintDayDiag(g_dayStart);
   ZeroMemory(g_diagD);
   DIAG(days);
   g_dayStart     = d;
   g_daySetupsMem = 0;
   g_dayStopCode  = 0;
   ArrayResize(g_lv, 0);
   g_asiaDone = false;
   g_pdOk     = false;
   string gv = GVName("daystop");
   g_dayStopped = GlobalVariableCheck(gv) && (long)GlobalVariableGet(gv) >= (long)d;
   if(g_dayStopped)
     {
      g_dayStopCode   = (int)GlobalVariableGet(GVName("daystopcode"));
      g_dayStopReason = DayStopText(g_dayStopCode);
     }
   else
      g_dayStopReason = "";
   UpdateDayStats();
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE) - g_dayRealized;
   RebuildLevels(now);
   g_status = "New day " + TimeToString(d, TIME_DATE) + ": mapping liquidity levels";
  }

void StopDay(const int code, const string detail)
  {
   if(g_dayStopped)
      return;
   g_dayStopped    = true;
   g_dayStopCode   = code;
   g_dayStopReason = DayStopText(code);
   GlobalVariableSet(GVName("daystop"), (double)g_dayStart);
   GlobalVariableSet(GVName("daystopcode"), (double)code);
   g_status = g_dayStopReason + " - no more scalps today";
   Print(g_eaName, ": ", g_dayStopReason, " - ", detail);
   TgSend(E_Stop() + " " + _Symbol + " SCALPER STOPPED FOR TODAY - " + g_dayStopReason + "\n" + detail
          + "\nTrading resumes on the next trading day.");
  }

void CheckDailyLimits(void)
  {
   if(g_dayStart == 0)
      return;
   double progress = g_dayRealized + (InpTargetIncludeFloating ? FloatingPL() : 0.0);
   double worst    = g_dayRealized + FloatingPL();
   if(!g_dayStopped)
     {
      double lossLim = (InpDailyMaxLossPct > 0 && g_dayStartBalance > 0) ? g_dayStartBalance * InpDailyMaxLossPct / 100.0 : 0.0;
      if(lossLim > 0 && worst <= -lossLim)
         StopDay(1, "Day result " + SignedMoney(worst) + " " + Currency() + " (limit -" + M2S(lossLim) + ")");
      else
         if(InpDailyProfitTarget > 0 && progress >= InpDailyProfitTarget)
            StopDay(2, "Day result " + SignedMoney(progress) + " " + Currency() + " (target " + M2S(InpDailyProfitTarget) + ")");
         else
            if(InpMaxConsecLosses > 0 && g_dayConsec >= InpMaxConsecLosses)
               StopDay(3, "Losing setups in a row: " + IntegerToString(g_dayConsec));
     }
   if(!g_dayStopped || g_dayStopCode == 3)
      return;                                // losses in a row: nothing is open any more
   if(g_dayStopCode == 2 && !InpTargetCloseTrades)
      return;
   int nP = 0, nR = 0;
   if(CountOurPositions(nP, nR) == 0)
      return;
   datetime now = TimeCurrent();
   long since = (long)now - (long)g_lastDayClose;
   if(g_lastDayClose > 0 && since >= 0 && since < 15)
      return;
   g_lastDayClose = now;
   CloseAllOurPositions(g_dayStopReason);
  }

datetime OldestPositionTime(void)
  {
   datetime oldest = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || !IsOurMagic(PositionGetInteger(POSITION_MAGIC)))
         continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(oldest == 0 || t < oldest)
         oldest = t;
     }
   return oldest;
  }

int NextNewsWithin(const datetime now, const int mins)
  {
   if(!InpUseNewsFilter)
      return -1;
   for(int i = 0; i < ArraySize(g_news); i++)
     {
      long dt = (long)g_news[i].time - (long)now;
      if(dt > 0 && dt <= (long)mins * 60)
         return i;
     }
   return -1;
  }

//--- scalps are never held overnight / over the weekend / into high-impact news / longer than the max hold time
void CheckTimeExits(const datetime now)
  {
   if(g_dayStart == 0)
      return;
   int nP = 0, nR = 0;
   if(CountOurPositions(nP, nR) == 0)
      return;
   datetime oldest = OldestPositionTime();
   long dayClose = (long)g_dayStart + (long)InpDailyCloseHour * 3600 + (long)InpDailyCloseMinute * 60;
   string reason = "";
   if(g_closeEffective > 0 && now >= g_closeEffective)
      reason = "Friday close before the weekend";
   else
      if(InpUseDailyClose && (long)now >= dayClose)
         reason = "Daily close " + StringFormat("%02d:%02d", InpDailyCloseHour, InpDailyCloseMinute) + " (before the rollover)";
      else
         if(oldest > 0 && oldest < g_dayStart)
            reason = "Scalp left over from the previous day";
         else
            if(InpMaxHoldMinutes > 0 && oldest > 0 && (long)now - (long)oldest >= (long)InpMaxHoldMinutes * 60)
               reason = "Max hold time " + IntegerToString(InpMaxHoldMinutes) + " min reached";
            else
              {
               int ni = (InpNewsCloseMinsBefore > 0) ? NextNewsWithin(now, InpNewsCloseMinsBefore) : -1;
               if(ni >= 0)
                  reason = "High-impact news in less than " + IntegerToString(InpNewsCloseMinsBefore) + " min: " + g_news[ni].name;
              }
   if(reason == "")
      return;
   long since = (long)now - (long)g_lastCloseAttempt;
   if(g_lastCloseAttempt > 0 && since >= 0 && since < 15)
      return;
   g_lastCloseAttempt = now;
   CloseAllOurPositions(reason);
  }

//+------------------------------------------------------------------+
//| Scalper: entries                                                 |
//+------------------------------------------------------------------+
string ConfirmModeText(void)
  {
   if(InpEntryConfirm == CONFIRM_REJECTION)
      return "rejection candle";
   string s = (InpEntryConfirm == CONFIRM_REJECTION_CHOCH) ? "rejection + ChoCH" : "ChoCH";
   if(InpRequireFVG)
      s += " + FVG";
   return s;
  }

double MaxSLPrice(void)
  {
   double m = InpMaxSL;
   if(m <= 0)
     {
      double atr = GetATR(g_hAtrM15, 1);
      m = (atr > 0) ? InpMaxSLATR * atr : 15.0;
     }
   return (m > InpMinSL) ? m : InpMinSL + 0.5;
  }

//--- gates that make looking for a signal pointless (limits, trade running, cooldown)
bool HardGate(const datetime now, string &why)
  {
   if(!g_isTester)
     {
      if(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) == 0 || MQLInfoInteger(MQL_TRADE_ALLOWED) == 0)
        {
         why = "Algo trading is disabled (Algo Trading button / EA settings)";
         return false;
        }
      if(AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) == 0 || AccountInfoInteger(ACCOUNT_TRADE_EXPERT) == 0)
        {
         why = "Trading not allowed on this account";
         return false;
        }
     }
   if(InpWeeklyProfitTarget > 0 && g_targetHit)
     {
      why = "Weekly profit target reached (" + TargetText() + ") - no new trades this week";
      return false;
     }
   if(g_dayStopped)
     {
      why = g_dayStopReason + " - no more scalps today";
      return false;
     }
   int setups = (g_daySetups > g_daySetupsMem) ? g_daySetups : g_daySetupsMem;
   if(setups >= InpMaxTradesPerDay)
     {
      why = "Daily limit reached (" + IntegerToString(setups) + "/" + IntegerToString(InpMaxTradesPerDay) + " setups)";
      return false;
     }
   if(InpMaxConsecLosses > 0 && g_dayConsec >= InpMaxConsecLosses)
     {
      why = IntegerToString(g_dayConsec) + " losing setups in a row - no more scalps today";
      return false;
     }
   int nP = 0, nR = 0;
   if(CountOurPositions(nP, nR) > 0)
     {
      why = "Scalp running";
      return false;
     }
   if(InpCooldownMinutes > 0 && g_dayLastClose > 0 && (long)now - (long)g_dayLastClose < (long)InpCooldownMinutes * 60)
     {
      why = "Cooldown after the last scalp (until " + TimeToString((datetime)((long)g_dayLastClose + (long)InpCooldownMinutes * 60), TIME_MINUTES) + ")";
      return false;
     }
   return true;
  }

//--- filters checked when a signal appears. code: 1 day / time, 2 killzone, 3 news, 4 spread, 5 volatility
bool SoftGate(const datetime now, string &why, int &code)
  {
   code = 1;
   int dow = DowOf(now);
   int hr  = HourOfDay(now);
   if(!TradeDayOk(dow))
     {
      why = "No scalping on " + DayName(dow);
      return false;
     }
   if(hr >= InpLastEntryHour)
     {
      why = "After the last entry hour";
      return false;
     }
   if(dow == 5 && hr >= InpFridayLastEntryHour)
     {
      why = "Friday entry cut-off reached";
      return false;
     }
   long dayClose = (long)g_dayStart + (long)InpDailyCloseHour * 3600 + (long)InpDailyCloseMinute * 60;
   if(InpUseDailyClose && (long)now >= dayClose - 1800)
     {
      why = "Too close to the daily close";
      return false;
     }
   if(g_closeEffective > 0 && (long)now >= (long)g_closeEffective - 3600)
     {
      why = "Too close to the weekend close";
      return false;
     }
   code = 2;
   string sess = "";
   if(!SessionAllows(now, sess))
     {
      why = "Killzone filter: " + sess;
      return false;
     }
   code = 3;
   int ni = BlockingNews(now);
   if(ni >= 0)
     {
      why = "News pause: " + g_news[ni].name + " at " + TimeToString(g_news[ni].time, TIME_MINUTES);
      return false;
     }
   code = 4;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
     {
      why = "No price";
      return false;
     }
   if(tick.ask - tick.bid > InpMaxSpread)
     {
      why = "Spread too high (" + P2S(tick.ask - tick.bid) + " > max " + P2S(InpMaxSpread) + ")";
      return false;
     }
   code = 5;
   double atr5 = GetATR(g_hAtrM5, 1);
   if(InpMinATR > 0 && atr5 > 0 && atr5 < InpMinATR)
     {
      why = "Market too quiet (M5 ATR " + P2S(atr5) + " < " + P2S(InpMinATR) + ")";
      return false;
     }
   if(InpMaxATR > 0 && atr5 > InpMaxATR)
     {
      why = "Market too volatile (M5 ATR " + P2S(atr5) + " > " + P2S(InpMaxATR) + ")";
      return false;
     }
   code = 0;
   return true;
  }

bool CanOpenNewSetup(string &why)
  {
   datetime now = TimeCurrent();
   if(!HardGate(now, why))
      return false;
   int code = 0;
   return SoftGate(now, why, code);
  }

//--- a 3-candle fair value gap in the displacement after the sweep candle 'tap' (series indexes)
bool HasFVG(const MqlRates &r[], const int count, const int tap, const int dir, double &gLo, double &gHi)
  {
   for(int i = 2; i <= tap - 1 && i + 1 < count; i++)
     {
      if(dir < 0 && r[i + 1].low > r[i - 1].high + _Point)
        {
         gLo = r[i - 1].high;
         gHi = r[i + 1].low;
         return true;
        }
      if(dir > 0 && r[i + 1].high < r[i - 1].low - _Point)
        {
         gLo = r[i + 1].high;
         gHi = r[i - 1].low;
         return true;
        }
     }
   return false;
  }

//--- signal at one swept level: SL anchor (sweep extreme), arrow position, sweep candle and break candle
bool FindScalpSignal(const SOrderBlock &poi, const MqlRates &m1[], const int count, const double atr, const int late,
                     string &pattern, double &ext, datetime &sigTime, double &sigPrice, int &tap, int &brk)
  {
   bool isSell = (poi.dir < 0);
   if(InpEntryConfirm == CONFIRM_REJECTION)
     {
      for(int c = 1; c <= late && c + 1 < count; c++)
        {
         string pt = "";
         if(!IsRejection(poi, m1, c, atr, pt))
            continue;
         pattern  = pt + " at the sweep";
         ext      = isSell ? m1[c].high : m1[c].low;
         sigTime  = m1[c].time;
         sigPrice = ext;
         tap      = c;
         brk      = c;
         return true;
        }
      return false;
     }
   double sweep = 0.0, level = 0.0;
   int b = 1;
   if(!CheckChoch(poi, m1, count, atr, late, pattern, sweep, level, b))
      return false;
   ext = sweep;
   tap = b;
   for(int s = b; s < count - 1; s++)
      if((isSell && m1[s].high == sweep) || (!isSell && m1[s].low == sweep))
        {
         tap = s;
         break;
        }
   brk      = b;
   sigTime  = m1[b].time;
   sigPrice = isSell ? m1[b].high : m1[b].low;
   return true;
  }

//--- returns 1 = opened, 0 = not opened (retry on a later signal), -1 = skipped for good (lot / risk limits)
int OpenScalp(const SOrderBlock &poi, const int li, const double sweepExt, const datetime sigTime, const double sigPrice,
              const string pattern, string &skipWhy, int &skipCode)
  {
   skipWhy  = "";
   skipCode = 0;
   bool isSell = (poi.dir < 0);
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
     {
      skipWhy  = "no price";
      skipCode = 3;
      return 0;
     }
   double spread  = tick.ask - tick.bid;
   double entry   = isSell ? tick.bid : tick.ask;
   double sl      = isSell ? sweepExt + InpSLBuffer + spread : sweepExt - InpSLBuffer;
   double minDist = StopsDistance() + spread;
   double minSL   = MathMax(InpMinSL, minDist);
   double risk    = isSell ? sl - entry : entry - sl;
   if(risk < minSL)
     {
      sl   = isSell ? entry + minSL : entry - minSL;
      risk = minSL;
     }
   double maxSL = MaxSLPrice();
   if(risk > maxSL)
     {
      skipWhy  = "SL " + P2S(risk) + " > max " + P2S(maxSL) + " (raise 'Maximum SL' / the M15 ATR multiple)";
      skipCode = 1;
      g_status = DirText(isSell) + " signal skipped: " + skipWhy;
      return 0;
     }

   //--- targets: TP1 at x R (partial), TP2 at x R and / or ATR trailing
   double tp1 = isSell ? entry - InpTP1RR * risk : entry + InpTP1RR * risk;
   if(MathAbs(tp1 - entry) < minDist)
      tp1 = isSell ? entry - minDist : entry + minDist;
   double tp2 = isSell ? entry - InpRewardRisk * risk : entry + InpRewardRisk * risk;
   string tp2Txt = "1:" + DoubleToString(InpRewardRisk, 1);
   if(InpTP2Mode == TP2_ATR_TRAIL)
     {
      tp2    = 0.0;
      tp2Txt = "ATR trailing stop after TP1 (" + TrailText() + ")";
      if(InpTrailHardTPRR > 0)
        {
         tp2 = isSell ? entry - InpTrailHardTPRR * risk : entry + InpTrailHardTPRR * risk;
         tp2Txt += ", far TP 1:" + DoubleToString(InpTrailHardTPRR, 1);
        }
     }
   else
      if(InpTP2Mode == TP2_RR_PLUS_TRAIL)
         tp2Txt += " + ATR trailing after TP1 (" + TrailText() + ")";
   sl  = NormPrice(sl);
   tp1 = NormPrice(tp1);
   if(tp2 > 0)
      tp2 = NormPrice(tp2);

   //--- volume
   double lotP = 0.0, lotR = 0.0, riskMoney = 0.0;
   string err = "";
   if(!CalcLots(isSell, entry, sl, lotP, lotR, riskMoney, err))
     {
      skipWhy  = err;
      skipCode = 2;
      g_status = DirText(isSell) + " signal skipped: " + err;
      return -1;
     }

   //--- send: 2 trades (hedging) or 1 trade + EA-managed partial (netting)
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
         string which = okP ? "TP1" : "TP2";
         warn = "\n" + E_Warn() + " Only the " + which + " trade could be opened.";
        }
     }
   if(!okP && !okR)
     {
      skipWhy  = "order rejected by the server: " + g_tradeP.ResultRetcodeDescription();
      skipCode = 3;
      g_status = "Order failed: " + g_tradeP.ResultRetcodeDescription();
      TgSend(E_X() + " " + _Symbol + " " + DirText(isSell) + " scalp FAILED: " + g_tradeP.ResultRetcodeDescription());
      return 0;
     }
   g_daySetupsMem++;
   GlobalVariableSet(GVName("setupT"), (double)TimeCurrent());

   double fill = okP ? g_tradeP.ResultPrice() : g_tradeR.ResultPrice();
   if(fill <= 0)
      fill = entry;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskPct = (bal > 0) ? riskMoney / bal * 100.0 : 0.0;
   DrawSignal(isSell, sigTime, sigPrice);

   string tp2Price = (tp2 > 0) ? P2S(tp2) : "trailing";
   string legs = "";
   if(g_netting)
      legs = E_Yellow() + " TP1 " + DoubleToString(InpTP1RR, 1) + "R: " + P2S(tp1) + " - EA closes " + L2S(lotP) + " lot\n"
             + E_Target() + " TP2: " + tp2Price + " (" + tp2Txt + ") - total " + L2S(FloorLot(lotP + lotR)) + " lot\n";
   else
      legs = E_Yellow() + " Trade 1 TP1 " + DoubleToString(InpTP1RR, 1) + "R: " + P2S(tp1) + " | " + L2S(lotP) + " lot\n"
             + E_Target() + " Trade 2 TP2: " + tp2Price + " (" + tp2Txt + ") | " + L2S(lotR) + " lot\n";
   string sess = "";
   SessionAllows(TimeCurrent(), sess);
   int setups = (g_daySetups > g_daySetupsMem) ? g_daySetups : g_daySetupsMem;
   string hold = (InpMaxHoldMinutes > 0) ? " | max hold " + IntegerToString(InpMaxHoldMinutes) + " min" : "";
   string msg = (isSell ? E_Down() : E_Up()) + " " + DirText(isSell) + " SCALP OPENED - " + _Symbol + "\n"
                + "Liquidity: sweep of the " + LevelName(g_lv[li]) + " " + P2S(g_lv[li].price) + " to " + P2S(sweepExt) + "\n"
                + "Signal: M1 " + pattern + "\n"
                + "Filters: bias " + TrendText(g_trendDir) + " | " + sess + " | spread " + P2S(spread) + "\n"
                + "Entry: " + P2S(fill) + "\n"
                + E_Stop() + " SL: " + P2S(sl) + " (" + P2S(risk) + " away)\n"
                + legs
                + "Risk: " + M2S(riskMoney) + " " + Currency() + " (" + DoubleToString(riskPct, 2) + "%)\n"
                + "Today: setup " + IntegerToString(setups) + "/" + IntegerToString(InpMaxTradesPerDay) + hold
                + warn;
   Print(DirText(isSell), " scalp opened: entry ", P2S(fill), " SL ", P2S(sl), " TP1 ", P2S(tp1), " TP2 ", tp2Price,
         " (sweep of ", LevelName(g_lv[li]), " ", P2S(g_lv[li].price), ")");
   TgSend(msg);
   TgSendScreenshot(_Symbol + " " + DirText(isSell) + " scalp @ " + P2S(fill) + " | SL " + P2S(sl) + " | TP1 " + P2S(tp1) + " | TP2 " + tp2Price);
   g_status = DirText(isSell) + " scalp running";
   return 1;
  }

void CheckEntries(void)
  {
   datetime now = TimeCurrent();
   int k    = (InpChochSwingBars > 0) ? InpChochSwingBars : 1;
   int need = InpChochWindow + InpChochSwingLookback + k + 6;
   if(need < 30)
      need = 30;
   MqlRates m1[];
   ArraySetAsSeries(m1, true);
   int count = CopyRates(_Symbol, PERIOD_M1, 0, need, m1);
   if(count < 10)
      return;

   //--- M1 candles closed since the previous check (> 1 when the tester skips ticks)
   int late = 1;
   if(g_lastEvalBar > 0)
     {
      late = 0;
      for(int s = 1; s < count && m1[s].time > g_lastEvalBar; s++)
         late++;
      if(late < 1)
         late = 1;
      if(late > 12)
         late = 12;
     }
   g_lastEvalBar = m1[1].time;

   double atr5 = GetATR(g_hAtrM5, 1);
   if(atr5 <= 0)
      atr5 = 3.0 * (m1[1].high - m1[1].low);
   double minPierce = InpSweepMinATR * atr5;
   double maxSweep  = InpSweepMaxATR * atr5;

   //--- an M1 close beyond 'level + max sweep' = breakout: the level is done for the day
   bool redraw = false;
   for(int s = late; s >= 1; s--)
      for(int i = 0; i < ArraySize(g_lv); i++)
        {
         if(g_lv[i].broken)
            continue;
         if((g_lv[i].side > 0 && m1[s].close > g_lv[i].price + maxSweep) || (g_lv[i].side < 0 && m1[s].close < g_lv[i].price - maxSweep))
           {
            g_lv[i].broken = true;
            redraw = true;
           }
        }
   if(redraw)
      DrawLevels();

   string why = "";
   if(!HardGate(now, why))
     {
      g_status = why;
      return;
     }

   //--- points of interest: the sweep band beyond every active level
   SOrderBlock poi[];
   int src[];
   for(int i = 0; i < ArraySize(g_lv); i++)
     {
      if(g_lv[i].broken || g_lv[i].used)
         continue;
      SOrderBlock z;
      z.time  = g_lv[i].time;
      z.dir   = -g_lv[i].side;
      z.valid = true;
      z.used  = false;
      if(g_lv[i].side > 0)
        {
         z.low  = g_lv[i].price + minPierce;
         z.high = g_lv[i].price + maxSweep;
        }
      else
        {
         z.low  = g_lv[i].price - maxSweep;
         z.high = g_lv[i].price - minPierce;
        }
      PushPOI(poi, src, z, i);
     }
   int active = ArraySize(poi);
   if(active == 0)
     {
      g_status = "Watching: no active liquidity level (waiting for the Asian range / new levels)";
      return;
     }
   DIAG(barsWatched);
   bool touched = false;
   for(int i = 0; i < active && !touched; i++)
      for(int s = 1; s <= late && !touched; s++)
         if(m1[s].high >= poi[i].low && m1[s].low <= poi[i].high)
            touched = true;
   if(touched)
      DIAG(barsTouch);

   double atrM1 = GetATR(g_hAtrM1, 1);
   if(atrM1 <= 0)
      atrM1 = m1[1].high - m1[1].low;
   g_trendDir = TrendDir();
   string softWhy = "";
   int softCode = 0;
   bool softOk = SoftGate(now, softWhy, softCode);
   if(softOk)
      g_status = "Watching " + IntegerToString(active) + " liquidity level(s) for a sweep + M1 " + ConfirmModeText();
   else
      g_status = softWhy;

   int blockedDirs = 0;                      // bit 1 = sell, bit 2 = buy: already blocked by a filter this bar
   for(int i = 0; i < active; i++)
     {
      int bit = (poi[i].dir < 0) ? 1 : 2;
      if((blockedDirs & bit) != 0)
         continue;
      string pattern = "";
      double ext = 0.0, sigPrice = 0.0;
      datetime sigTime = 0;
      int tap = 1, brk = 1;
      if(!FindScalpSignal(poi[i], m1, count, atrM1, late, pattern, ext, sigTime, sigPrice, tap, brk))
         continue;
      int li = src[i];
      bool isSell = (poi[i].dir < 0);
      string tag = DirText(isSell) + " after the sweep of the " + LevelName(g_lv[li]) + " " + P2S(g_lv[li].price) + " [" + pattern + "]";
      DIAG(signals);
      double gLo = 0.0, gHi = 0.0;
      if(InpRequireFVG && InpEntryConfirm != CONFIRM_REJECTION && !HasFVG(m1, count, tap, poi[i].dir, gLo, gHi))
        {
         DIAG(blkFVG);
         LogSignal(tag, "no M1 fair value gap in the displacement");
         continue;
        }
      if(!TrendAllows(poi[i].dir, g_trendDir))
        {
         DIAG(blkTrend);
         LogSignal(tag, "bias " + TrendText(g_trendDir));
         blockedDirs |= bit;
         continue;
        }
      if(!softOk)
        {
         if(softCode == 1)
            DIAG(blkTime);
         if(softCode == 2)
            DIAG(blkSession);
         if(softCode == 3)
            DIAG(blkNews);
         if(softCode == 4)
            DIAG(blkSpread);
         if(softCode == 5)
            DIAG(blkVol);
         LogSignal(tag, softWhy);
         blockedDirs |= bit;
         continue;
        }
      string skip = "";
      int code = 0;
      int res = OpenScalp(poi[i], li, ext, sigTime, sigPrice, pattern, skip, code);
      if(res > 0)
        {
         DIAG(opened);
         g_lv[li].used = true;
         DrawLevels();
         break;
        }
      if(code == 1)
         DIAG(skipMaxSL);
      if(code == 2)
         DIAG(skipLots);
      if(code == 3)
         DIAG(failOrder);
      LogSignal(tag, skip);
      if(res < 0)
        {
         g_lv[li].used = true;               // skipped for good (lot / risk limits)
         DrawLevels();
        }
     }
  }

//+------------------------------------------------------------------+
//| Scalper: diagnostics                                             |
//+------------------------------------------------------------------+
string DiagLine(const SDiag &d)
  {
   return "levels " + IntegerToString(d.levels) + " | M1 bars at a sweep " + IntegerToString(d.barsTouch) + "/" + IntegerToString(d.barsWatched)
          + " | signals " + IntegerToString(d.signals) + " -> opened " + IntegerToString(d.opened)
          + " (no FVG " + IntegerToString(d.blkFVG) + ", bias " + IntegerToString(d.blkTrend)
          + ", killzone " + IntegerToString(d.blkSession) + ", news " + IntegerToString(d.blkNews)
          + ", day/time " + IntegerToString(d.blkTime) + ", spread " + IntegerToString(d.blkSpread)
          + ", volatility " + IntegerToString(d.blkVol) + ", SL>max " + IntegerToString(d.skipMaxSL)
          + ", lot/risk " + IntegerToString(d.skipLots) + ", order failed " + IntegerToString(d.failOrder) + ")";
  }

void PrintDayDiag(const datetime d)
  {
   Print("DAY ", TimeToString(d, TIME_DATE), ": ", DiagLine(g_diagD));
  }

string DiagReportText(void)
  {
   SDiag d;
   d = g_diag;
   string s = E_Chart() + " " + g_eaName + " v" + g_eaVer + " - DIAGNOSTICS (" + _Symbol + ")\n";
   s += "Days: " + IntegerToString(d.days) + " | liquidity levels mapped: " + IntegerToString(d.levels) + "\n";
   s += "M1 bars watched (no limit / trade blocking): " + IntegerToString(d.barsWatched)
        + " | price sweeping a level: " + IntegerToString(d.barsTouch) + "\n";
   s += "Signals (sweep + M1 " + ConfirmModeText() + "): " + IntegerToString(d.signals) + "\n";
   s += "  blocked - no fair value gap: " + IntegerToString(d.blkFVG) + "\n";
   s += "  blocked - HTF bias: " + IntegerToString(d.blkTrend) + "\n";
   s += "  blocked - outside the killzones: " + IntegerToString(d.blkSession) + "\n";
   s += "  blocked - news filter: " + IntegerToString(d.blkNews) + "\n";
   s += "  blocked - day / time / daily close: " + IntegerToString(d.blkTime) + "\n";
   s += "  blocked - spread: " + IntegerToString(d.blkSpread) + "\n";
   s += "  blocked - volatility: " + IntegerToString(d.blkVol) + "\n";
   s += "  skipped - SL above maximum: " + IntegerToString(d.skipMaxSL) + "\n";
   s += "  skipped - lot / risk / margin: " + IntegerToString(d.skipLots) + "\n";
   s += "  order rejected: " + IntegerToString(d.failOrder) + "\n";
   s += "Setups opened: " + IntegerToString(d.opened) + "\n";
   string tip = "";
   if(d.days < 5)
      tip = "Test a longer period (at least 1 month) on M1 or M5 with 'Every tick based on real ticks'.";
   else
      if(d.levels == 0)
         tip = "No liquidity levels were mapped: check that D1 / H1 / M5 history is available for the test period.";
      else
         if(d.barsTouch == 0)
            tip = "Price never swept a level while trading was allowed: enable more levels (H1 swings) or lower 'A sweep pierces the level by >= x M5 ATR'.";
         else
            if(d.signals == 0)
               tip = "Levels were swept but no M1 confirmation formed: raise the ChoCH window, lower the M1 swing strength, or set 'Entry confirmation' = rejection candle.";
   if(tip == "" && d.opened == 0 && d.signals > 0)
     {
      int mx = d.blkFVG;
      tip = "Most signals had no M1 fair value gap: set 'The displacement must leave an M1 fair value gap' = false.";
      if(d.blkTrend > mx)
        {
         mx = d.blkTrend;
         tip = "Most signals were against the HTF bias: set 'Bias filter mode' = Off.";
        }
      if(d.blkSession > mx)
        {
         mx = d.blkSession;
         tip = "Most signals were outside the killzones: widen the London / New York hours or switch the killzone filter off.";
        }
      if(d.blkNews > mx)
        {
         mx = d.blkNews;
         tip = "Most signals were inside a news pause: lower the news minutes or switch the news filter off.";
        }
      if(d.blkTime > mx)
        {
         mx = d.blkTime;
         tip = "Most signals were outside the trading days / hours: check the day switches and the last entry hour.";
        }
      if(d.blkSpread > mx)
        {
         mx = d.blkSpread;
         tip = "Most signals had a too-wide spread: raise 'Maximum spread' (the tester uses your broker's spread).";
        }
      if(d.blkVol > mx)
        {
         mx = d.blkVol;
         tip = "Most signals were blocked by the volatility filter: adjust 'Minimum / Maximum M5 ATR'.";
        }
      if(d.skipMaxSL > mx)
        {
         mx = d.skipMaxSL;
         tip = "Most signals needed a stop wider than the maximum: raise 'Maximum SL' or 'Automatic maximum SL = x M15 ATR'.";
        }
      if(d.skipLots > mx)
        {
         mx = d.skipLots;
         tip = "The deposit is too small for 2 x minimum lot at this stop: raise the deposit, 'Max risk %', or use Lot mode = Fixed.";
        }
      if(d.failOrder > mx)
         tip = "Orders were rejected by the server: see the Journal for the error code.";
     }
   if(tip != "")
      s += "TIP: " + tip;
   return s;
  }

void PrintDiagReport(void)
  {
   string lines[];
   int n = StringSplit(DiagReportText(), '\n', lines);
   for(int i = 0; i < n; i++)
      if(lines[i] != "")
         Print(lines[i]);
  }

//+------------------------------------------------------------------+
//| Scalper: panel + Telegram texts                                  |
//+------------------------------------------------------------------+
void UpdatePanel(void)
  {
   if(!InpShowPanel || !g_visual)
      return;
   g_lastPanelUpdate = TimeLocal();
   datetime now = ServerNow();
   MqlTick tick;
   double spread = SymbolInfoTick(_Symbol, tick) ? tick.ask - tick.bid : 0.0;
   double atr5 = GetATR(g_hAtrM5, 1);
   int nP = 0, nR = 0;
   int open = CountOurPositions(nP, nR);
   int setups = (g_daySetups > g_daySetupsMem) ? g_daySetups : g_daySetupsMem;
   g_trendDir = TrendDir();
   string acc   = g_netting ? "NETTING" : "HEDGING";
   string tg    = TgReady() ? "ON" : (InpTelegramEnable ? "check token / chat id" : "OFF");
   string sess  = "";
   string state = SessionAllows(now, sess) ? "OPEN " : "CLOSED ";
   int ni = BlockingNews(now);
   string news  = (!InpUseNewsFilter) ? "off" : (ni >= 0 ? "PAUSED " + StringSubstr(g_news[ni].name, 0, 30) : "clear");
   string day   = g_dayStopped ? "STOPPED - " + g_dayStopReason : "active";
   string pd    = g_pdOk ? "PDH " + P2S(g_pdh) + "   PDL " + P2S(g_pdl) : "PDH / PDL: n/a";
   string asia  = g_asiaDone ? "Asia H " + P2S(g_asiaHigh) + "   L " + P2S(g_asiaLow) : "Asian range: forming";
   string L[];
   PushLine(L, g_eaName + " v" + g_eaVer + "  [" + acc + "]");
   PushLine(L, "Server " + DayTime(now) + "  spread " + P2S(spread) + "  M5 ATR " + P2S(atr5));
   PushLine(L, pd);
   PushLine(L, asia);
   PushLine(L, "Active levels: " + IntegerToString(ActiveLevelCount(+1)) + " highs / " + IntegerToString(ActiveLevelCount(-1)) + " lows");
   PushLine(L, "Today: setups " + IntegerToString(setups) + "/" + IntegerToString(InpMaxTradesPerDay) + "  net " + SignedMoney(g_dayRealized)
            + "  losses in a row " + IntegerToString(g_dayConsec));
   PushLine(L, "Day: " + StringSubstr(day, 0, 50));
   PushLine(L, "Open trades " + IntegerToString(open) + "  float " + SignedMoney(FloatingPL()));
   PushLine(L, "Week target: " + TargetText());
   PushLine(L, "Killzone: " + state + StringSubstr(sess, 0, 40));
   PushLine(L, "News: " + news + " | bias: " + TrendText(g_trendDir));
   PushLine(L, "Signals " + IntegerToString(g_diag.signals) + " | opened " + IntegerToString(g_diag.opened)
            + (g_lastBlock != "" ? " | last block: " + StringSubstr(g_lastBlock, 0, 30) : ""));
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
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, 490);
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

string HelpText(void)
  {
   return E_Bot() + " " + g_eaName + " - commands\n"
          + "/status - scalper status, open trades, today's P/L\n"
          + "/levels - today's liquidity map (PDH/PDL, Asian range, H1 swings)\n"
          + "/report - today's report\n"
          + "/news - upcoming high-impact news (48h)\n"
          + "/diag - why scalps were / were not taken\n"
          + "/chart - chart screenshot\n"
          + "/help - this list";
  }

string BuildLevelsText(void)
  {
   string s = E_Chart() + " LIQUIDITY MAP - " + _Symbol + " - " + DayName(DowOf(g_dayStart)) + " " + TimeToString(g_dayStart, TIME_DATE) + "\n";
   s += LevelsText();
   s += "Killzones: " + SessionSetupText() + "\n";
   s += "Bias: " + TrendText(TrendDir()) + "\n";
   s += "High-impact news (24h):\n" + UpcomingNewsText(ServerNow(), 24);
   s += "Plan: wait for a sweep of a level, then an M1 " + ConfirmModeText() + " - scalp back toward the other side.";
   return s;
  }

string BuildStatusText(void)
  {
   datetime now = ServerNow();
   int nP = 0, nR = 0;
   int n = CountOurPositions(nP, nR);
   int setups = (g_daySetups > g_daySetupsMem) ? g_daySetups : g_daySetupsMem;
   string day = g_dayStopped ? g_dayStopReason : "active";
   string s = E_Bot() + " SCALPER STATUS - " + _Symbol + "\n";
   s += "Server: " + DayTime(now) + "\n";
   s += "EA: " + g_status + "\n";
   s += FiltersStatusText(now);
   s += "Today: setups " + IntegerToString(setups) + "/" + IntegerToString(InpMaxTradesPerDay) + " | net " + SignedMoney(g_dayRealized)
        + " | losing setups in a row " + IntegerToString(g_dayConsec) + "\n";
   s += "Day: " + day + " | week target " + TargetText() + "\n";
   s += "Open trades: " + IntegerToString(n) + "\n" + OpenPositionsText();
   s += "Floating: " + SignedMoney(FloatingPL()) + " " + Currency() + "\n";
   s += "Balance: " + M2S(AccountInfoDouble(ACCOUNT_BALANCE)) + " | Equity: " + M2S(AccountInfoDouble(ACCOUNT_EQUITY));
   return s;
  }

string BuildDailyReport(const datetime dayStart)
  {
   SStats d;
   CalcStats(dayStart, (datetime)((long)dayStart + 86400), d);
   string day = g_dayStopped ? g_dayStopReason : "active";
   string s = E_Chart() + " SCALPER DAILY REPORT - " + _Symbol + " - " + DayName(DowOf(dayStart)) + " " + TimeToString(dayStart, TIME_DATE) + "\n";
   s += "Setups: " + IntegerToString(d.setups) + "/" + IntegerToString(InpMaxTradesPerDay) + " | trades closed " + IntegerToString(d.closed)
        + " | W " + IntegerToString(d.wins) + " / L " + IntegerToString(d.losses) + "\n";
   s += "Net: " + SignedMoney(d.net) + " " + Currency() + " | losing setups in a row " + IntegerToString(g_dayConsec) + "\n";
   s += "Day: " + day + "\n";
   s += "Weekly profit target: " + TargetText() + "\n";
   s += "Open trades:\n" + OpenPositionsText();
   s += "Balance: " + M2S(AccountInfoDouble(ACCOUNT_BALANCE)) + " | Equity: " + M2S(AccountInfoDouble(ACCOUNT_EQUITY)) + "\n";
   s += "Next 24h high-impact news:\n" + UpcomingNewsText(ServerNow(), 24);
   return s;
  }

string BuildWeeklyReport(const datetime ws)
  {
   SStats w;
   CalcStats(ws, (datetime)((long)ws + 7 * 86400), w);
   int decided = w.wins + w.losses;
   double wr = (decided > 0) ? 100.0 * w.wins / decided : 0.0;
   string s = E_Cal() + " SCALPER WEEKLY REPORT - " + _Symbol + " - week of " + TimeToString(ws, TIME_DATE) + "\n";
   s += "Setups: " + IntegerToString(w.setups) + " (each = TP1 trade + TP2 trade)\n";
   s += "Trades closed: " + IntegerToString(w.closed) + " | Wins " + IntegerToString(w.wins) + " | Losses " + IntegerToString(w.losses)
        + " | Win rate " + DoubleToString(wr, 1) + "%\n";
   s += "Net P/L: " + SignedMoney(w.net) + " " + Currency() + "\n";
   if(InpWeeklyProfitTarget > 0)
     {
      string reached = (w.net >= InpWeeklyProfitTarget || g_targetHit) ? "REACHED" : "not reached";
      s += "Weekly profit target " + M2S(InpWeeklyProfitTarget) + " " + Currency() + ": " + reached + "\n";
     }
   s += "Balance: " + M2S(AccountInfoDouble(ACCOUNT_BALANCE)) + " | Equity: " + M2S(AccountInfoDouble(ACCOUNT_EQUITY)) + "\n";
   s += E_Ok() + " Week finished - no scalps held over the weekend.";
   return s;
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
      if(cmd == "/levels")
         TgSend(BuildLevelsText());
      else
         if(cmd == "/report")
            TgSend(BuildDailyReport(g_dayStart));
         else
            if(cmd == "/news")
               TgSend(BuildNewsText());
            else
               if(cmd == "/diag")
                  TgSend(DiagReportText());
               else
                  if(cmd == "/chart")
                     TgSendScreenshot(_Symbol + " - " + DayTime(ServerNow()) + " (server)");
                  else
                     if(cmd == "/help" || cmd == "/start")
                        TgSend(HelpText());
  }

void NewsAlertCheck(const datetime now)
  {
   if(!InpUseNewsFilter || !InpTgNewsAlerts || !InpTelegramEnable)
      return;
   if(!TradeDayOk(DowOf(now)))
      return;
   int i = BlockingNews(now);
   if(i < 0 || g_news[i].time == g_lastNewsAlert)
      return;
   g_lastNewsAlert = g_news[i].time;
   datetime until = (datetime)((long)g_news[i].time + (long)InpNewsMinsAfter * 60);
   string closeTxt = (InpNewsCloseMinsBefore > 0) ? " Open scalps are closed " + IntegerToString(InpNewsCloseMinsBefore) + " min before the release." : "";
   TgSend(E_Warn() + " NEWS PAUSE - " + _Symbol + "\n" + NewsLine(i) + "\n"
          + "No new scalps until " + DayTime(until) + " (server)." + closeTxt);
  }

void LevelsMapCheck(const datetime now)
  {
   if(!InpTelegramEnable || g_dayStart == 0)
      return;
   if(InpLiqAsia && !g_asiaDone)
      return;
   if(!TradeDayOk(DowOf(now)))
      return;
   string gv = GVName("lvmap");
   if(GlobalVariableCheck(gv) && (long)GlobalVariableGet(gv) >= (long)g_dayStart)
      return;
   GlobalVariableSet(gv, (double)g_dayStart);
   TgSend(BuildLevelsText());
   TgSendScreenshot(_Symbol + " - liquidity levels for today (PDH/PDL, Asian range, H1 swings)");
  }

void DailyReportCheck(const datetime now)
  {
   if(!InpTelegramEnable || !InpTgDailyReport || g_dayStart == 0)
      return;
   int dow = DowOf(now);
   if(dow == 0 || dow == 6)
      return;
   if(MinuteOfDay(now) < InpTgDailyHour * 60 + InpTgDailyMinute)
      return;
   string gv = GVName("daily");
   if(GlobalVariableCheck(gv) && (long)GlobalVariableGet(gv) >= (long)g_dayStart)
      return;
   GlobalVariableSet(gv, (double)g_dayStart);
   TgSend(BuildDailyReport(g_dayStart));
  }

void WeeklyReportCheck(const datetime now)
  {
   if(!InpTelegramEnable || g_closeEffective == 0 || now < g_closeEffective)
      return;
   int nP = 0, nR = 0;
   if(CountOurPositions(nP, nR) > 0)
      return;
   string gv = GVName("weekly");
   if(GlobalVariableCheck(gv) && (long)GlobalVariableGet(gv) >= (long)g_curWeekStart)
      return;
   GlobalVariableSet(gv, (double)g_curWeekStart);
   TgSend(BuildWeeklyReport(g_curWeekStart));
  }

void PeriodicChecks(const datetime now)
  {
   EnsureWeek(now);
   EnsureDay(now);
   RefreshNews(now);
   NewsAlertCheck(now);
   CheckWeeklyTarget();
   CheckDailyLimits();
   CheckTimeExits(now);
   WeeklyReportCheck(now);
   DailyReportCheck(now);
  }

bool ValidateInputs(void)
  {
   string e = "";
   if(InpTP1RR <= 0 || InpRewardRisk <= 0)
      e = "TP1 / TP2 R multiples must be > 0";
   else
      if(InpTP2Mode != TP2_ATR_TRAIL && InpRewardRisk <= InpTP1RR)
         e = "TP2 R must be greater than TP1 R";
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
                  if(InpMaxTradesPerDay < 1)
                     e = "Max setups per day must be >= 1";
                  else
                     if(InpAsiaRangeStartGMT < 0 || InpAsiaRangeEndGMT > 24 || InpAsiaRangeStartGMT >= InpAsiaRangeEndGMT)
                        e = "Asian range hours must be 0 <= start < end <= 24 (GMT)";
                     else
                        if(InpSweepMinATR < 0 || InpSweepMaxATR <= InpSweepMinATR)
                           e = "Sweep: the maximum must be greater than the minimum";
                        else
                           if(InpMinSL <= 0)
                              e = "Minimum SL must be > 0";
                           else
                              if((InpMaxSL > 0 && InpMaxSL <= InpMinSL) || (InpMaxSL <= 0 && InpMaxSLATR <= 0))
                                 e = "Max SL must be greater than min SL (or 0 with a positive M15 ATR multiple)";
                              else
                                 if(InpChochSwingBars < 1 || InpChochWindow < 3 || InpChochSwingLookback < 3)
                                    e = "ChoCH settings are invalid";
                                 else
                                    if(InpDailyCloseHour < 0 || InpDailyCloseHour > 23 || InpDailyCloseMinute < 0 || InpDailyCloseMinute > 59)
                                       e = "Daily close time is invalid";
                                    else
                                       if(InpATRPeriod < 2 || InpH1SwingLookback < 5 || InpH1SwingStrength < 1)
                                          e = "ATR / H1 swing settings are invalid";
                                       else
                                          if(InpWeeklyProfitTarget < 0 || InpDailyProfitTarget < 0 || InpDailyMaxLossPct < 0 || InpMaxConsecLosses < 0)
                                             e = "Targets / loss limits must be >= 0";
   if(e == "" && InpTP2Mode != TP2_FIXED_RR && (InpTrailATRPeriod < 2 || InpTrailATRMult <= 0 || InpTrailStep < 0))
      e = "Trailing stop settings are invalid";
   if(e == "" && InpTrendMode != TREND_OFF && (InpTrendMAPeriod < 2 || InpTrendLookback < 20 || InpTrendSwingBars < 1))
      e = "Bias filter settings are invalid";
   if(e == "" && InpUseNewsFilter && (InpNewsMinsBefore < 0 || InpNewsMinsAfter < 0 || InpNewsCloseMinsBefore < 0))
      e = "News minutes must be >= 0";
   if(e == "" && (InpLondonStartHour < 0 || InpLondonStartHour > 24 || InpLondonEndHour < 0 || InpLondonEndHour > 24 ||
                  InpNYStartHour < 0 || InpNYStartHour > 24 || InpNYEndHour < 0 || InpNYEndHour > 24 ||
                  InpAsiaStartHour < 0 || InpAsiaStartHour > 24 || InpAsiaEndHour < 0 || InpAsiaEndHour > 24))
      e = "Killzone hours must be between 0 and 24";
   if(e == "" && InpUseSessionFilter && !InpSessLondon && !InpSessNewYork && !InpSessAsia)
      e = "Killzone filter is on but no session is selected";
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

   g_hAtrM1  = iATR(_Symbol, PERIOD_M1, InpATRPeriod);
   g_hAtrM5  = iATR(_Symbol, PERIOD_M5, InpATRPeriod);
   g_hAtrM15 = iATR(_Symbol, PERIOD_M15, InpATRPeriod);
   if(g_hAtrM1 == INVALID_HANDLE || g_hAtrM5 == INVALID_HANDLE || g_hAtrM15 == INVALID_HANDLE)
     {
      Print(g_eaName, ": failed to create ATR handles, error ", GetLastError());
      return INIT_FAILED;
     }
   if(InpTP2Mode != TP2_FIXED_RR)
     {
      g_hAtrTrail = iATR(_Symbol, InpTrailTF, InpTrailATRPeriod);
      if(g_hAtrTrail == INVALID_HANDLE)
        {
         Print(g_eaName, ": failed to create the trailing ATR handle, error ", GetLastError());
         return INIT_FAILED;
        }
     }
   if(InpTrendMode == TREND_MA || InpTrendMode == TREND_MA_AND_STRUCTURE)
     {
      g_hTrendMA = iMA(_Symbol, InpTrendTF, InpTrendMAPeriod, 0, InpTrendMAMethod, PRICE_CLOSE);
      if(g_hTrendMA == INVALID_HANDLE)
        {
         Print(g_eaName, ": failed to create the bias MA handle, error ", GetLastError());
         return INIT_FAILED;
        }
     }
   ArrayResize(g_trailTickets, 0);
   ArrayResize(g_news, 0);
   ArrayResize(g_lv, 0);
   g_newsLoaded = 0;

   g_tgToken = InpTelegramToken;
   g_tgChat  = InpTelegramChatId;
   StringTrimLeft(g_tgToken);
   StringTrimRight(g_tgToken);
   StringTrimLeft(g_tgChat);
   StringTrimRight(g_tgChat);
   if(GlobalVariableCheck(GVName("tgoffset")))
      g_tgOffset = (long)GlobalVariableGet(GVName("tgoffset"));

   g_curWeekStart      = 0;
   g_dayStart          = 0;
   g_lastM1Bar         = 0;
   g_lastH1Bar         = 0;
   g_lastEvalBar       = 0;
   g_lastReportedSetup = 0;
   g_lastBlock         = "";
   ZeroMemory(g_diag);
   ZeroMemory(g_diagD);
   datetime now = ServerNow();
   EnsureWeek(now);
   EnsureDay(now);

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
         string loss = (InpDailyMaxLossPct > 0) ? DoubleToString(InpDailyMaxLossPct, 1) + "%" : "off";
         string news = InpUseNewsFilter ? IntegerToString(InpNewsMinsBefore) + "/" + IntegerToString(InpNewsMinsAfter) + " min" : "off";
         TgSend(E_Bot() + " " + g_eaName + " v" + g_eaVer + " started\n"
                + "Symbol: " + _Symbol + " | Account " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + " (" + acc + ")\n"
                + "Model: liquidity sweep -> M1 " + ConfirmModeText() + " | TP1 " + DoubleToString(InpTP1RR, 1) + "R + TP2 " + TP2ModeText() + "\n"
                + "Risk: " + risk + " | max " + IntegerToString(InpMaxTradesPerDay) + " setups / day | stop after "
                + IntegerToString(InpMaxConsecLosses) + " losses in a row\n"
                + "Daily loss limit: " + loss + " | weekly target: " + TargetText() + "\n"
                + "Killzones: " + SessionSetupText() + " | news filter: " + news + "\n"
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
   if(g_dayStart > 0)
      PrintDayDiag(g_dayStart);
   PrintDiagReport();
   if(g_hAtrM1 != INVALID_HANDLE)
      IndicatorRelease(g_hAtrM1);
   if(g_hAtrM5 != INVALID_HANDLE)
      IndicatorRelease(g_hAtrM5);
   if(g_hAtrM15 != INVALID_HANDLE)
      IndicatorRelease(g_hAtrM15);
   if(g_hAtrTrail != INVALID_HANDLE)
      IndicatorRelease(g_hAtrTrail);
   if(g_hTrendMA != INVALID_HANDLE)
      IndicatorRelease(g_hTrendMA);
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
   ManageTrailing();

   datetime h1 = iTime(_Symbol, PERIOD_H1, 0);
   datetime m1 = iTime(_Symbol, PERIOD_M1, 0);
   bool newM1  = (m1 > 0 && m1 != g_lastM1Bar);

   //--- liquidity levels: rebuilt every hour (new H1 swings) and when the Asian range completes
   if(h1 > 0 && h1 != g_lastH1Bar)
     {
      g_lastH1Bar = h1;
      RebuildLevels(now);
      LevelsMapCheck(now);
     }

   //--- entries and trade management on every new M1 candle
   if(newM1)
     {
      g_lastM1Bar = m1;
      if(ArraySize(g_lv) == 0 || (InpLiqAsia && !g_asiaDone && g_asiaEndSrv > 0 && (long)now >= (long)g_asiaEndSrv))
        {
         RebuildLevels(now);
         LevelsMapCheck(now);
        }
      UpdateDayStats();
      ManageRunners();
      CheckEntries();
      UpdatePanel();
     }
  }

//+------------------------------------------------------------------+
//| Timer (live only): time exits without ticks, reports, commands   |
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
//| Trade events: TP1 / TP2 / SL / time exits / daily limits         |
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
      title = tp1Leg ? E_Yellow() + " TP1 HIT (" + DoubleToString(InpTP1RR, 1) + "R) - partial taken"
              : E_Target() + " TP2 HIT - full target";
   else
      if(reason == DEAL_REASON_SL)
        {
         bool runner = (magic == g_magicR || g_netting);
         if(profit > 0 && runner && InpTP2Mode != TP2_FIXED_RR)
            title = E_Target() + " TRAILING STOP HIT - profit locked";
         else
            title = (profit >= 0) ? E_Shield() + " Stopped at breakeven / in profit" : E_Stop() + " STOP LOSS HIT";
        }
      else
         if(reason == DEAL_REASON_SO)
            title = E_Warn() + " STOP OUT (margin)";
         else
            if(reason == DEAL_REASON_EXPERT)
              {
               if(g_netting && stillOpen)
                  title = E_Yellow() + " TP1 HIT - partial closed by the EA";
               else
                  title = E_Clock() + " " + (g_lastCloseReason != "" ? g_lastCloseReason : "Closed by the EA");
              }
            else
               title = E_Warn() + " Closed manually / externally";

   string leg = tp1Leg ? "Trade 1 (TP1)" : (magic == g_magicR ? "Trade 2 (TP2)" : "Position");
   string msg = title + "\n"
                + _Symbol + " " + leg + " | " + L2S(vol) + " lot @ " + P2S(price) + "\n"
                + "Result: " + SignedMoney(profit) + " " + Currency() + "\n"
                + "Balance: " + M2S(AccountInfoDouble(ACCOUNT_BALANCE)) + " | Equity: " + M2S(AccountInfoDouble(ACCOUNT_EQUITY));
   Print(_Symbol, " ", leg, " closed @ ", P2S(price), " result ", SignedMoney(profit));
   TgSend(msg);

   UpdateDayStats();
   UpdateWeekRealized();
   CheckWeeklyTarget();

   //--- setup finished (no trade left): result + losing streak
   int nP = 0, nR = 0;
   if(CountOurPositions(nP, nR) == 0)
     {
      datetime key = GlobalVariableCheck(GVName("setupT")) ? (datetime)(long)GlobalVariableGet(GVName("setupT")) : 0;
      if(key > 0 && key != g_lastReportedSetup)
        {
         g_lastReportedSetup = key;
         SStats st;
         CalcStats((datetime)((long)key - 5), (datetime)((long)TimeCurrent() + 60), st);
         TgSend((st.net >= 0 ? E_Ok() : E_X()) + " SCALP FINISHED - " + _Symbol + ": " + SignedMoney(st.net) + " " + Currency() + "\n"
                + "Today: " + SignedMoney(g_dayRealized) + " " + Currency() + " | losing setups in a row " + IntegerToString(g_dayConsec)
                + " | cooldown " + IntegerToString(InpCooldownMinutes) + " min");
        }
     }
   CheckDailyLimits();
   ManageRunners();
   UpdatePanel();
  }
//+------------------------------------------------------------------+
