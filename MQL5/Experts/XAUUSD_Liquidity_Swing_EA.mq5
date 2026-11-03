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
//|                                                                  |
//|  v2.00 FILTERS & MANAGEMENT                                      |
//|  7. High-impact news filter: no new entries 30 min before /      |
//|     after high-impact USD news (MT5 economic calendar; manual    |
//|     list + NFP rule in the Strategy Tester).                     |
//|  8. Market session filter: entries only in London / New York    |
//|     (DST-aware, local exchange hours).                           |
//|  9. HTF trend filter: D1 / W1 moving average and / or market     |
//|     structure - sells only in a down trend, buys only in an up.  |
//| 10. ATR trailing stop for the TP2 trade once TP1 is hit          |
//|     (replaces the fixed 1:2 target, or runs on top of it).       |
//| 11. M5 ChoCH / structure-break confirmation after the OB touch.  |
//|                                                                  |
//|  v2.10                                                           |
//| 12. Up to 5 setups per week (each = TP1 trade + TP2 trade).      |
//| 13. Weekly profit target ($250): when reached, open trades are   |
//|     closed and no new trades are taken until next week.          |
//| 14. Entries at the H4 order blocks AND directly at the D1 sell / |
//|     buy zones (same M5 rejection + ChoCH confirmation).          |
//|                                                                  |
//|  v2.11 STRATEGY TESTER FIXES                                     |
//| 15. Max SL is automatic (1 x D1 ATR) instead of a fixed $40.     |
//| 16. Signals are not lost when the tester skips M5 bars           |
//|     ('Open prices only' / higher chart timeframe).               |
//| 17. Diagnostics: every blocked signal is logged in the Journal   |
//|     with its reason + a funnel report at the end of the test     |
//|     (also /diag in Telegram).                                    |
//+------------------------------------------------------------------+
#property copyright   "xauusd-pro-calculator"
#property link        "https://github.com/vinada08/xauusd-pro-calculator-"
#property version     "2.11"
#property description "XAUUSD swing EA: D1 Fri/Mon/Tue liquidity zones -> H4 order block -> M5 rejection + ChoCH entry."
#property description "Every setup = 2 trades: TP1 at the Tuesday D1 50% (yellow) + TP2 trade with ATR trailing stop (or 1:2)."
#property description "Filters: high-impact news, London/New York sessions, HTF trend. Wed/Thu/Fri only, weekly close Sat 04:30."

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
   SL_M5_CANDLE  = 1       // Beyond the M5 rejection candle / ChoCH swing (tighter)
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

enum ENUM_POI_MODE
  {
   POI_OB_ONLY     = 0,     // H4 order blocks only
   POI_ZONE_ONLY   = 1,     // D1 sell / buy zones only
   POI_OB_AND_ZONE = 2      // H4 order blocks + D1 zones
  };

enum ENUM_ENTRY_CONFIRM
  {
   CONFIRM_REJECTION       = 0, // Rejection candle only (pin bar / engulfing)
   CONFIRM_CHOCH           = 1, // M5 ChoCH / structure break only
   CONFIRM_REJECTION_CHOCH = 2  // Rejection candle + M5 ChoCH (strictest)
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== General ==="
input long            InpMagic                = 260611;          // Magic number (TP1 trade = magic, TP2 trade = magic+1)
input string          InpComment              = "XAU LiqSwing";  // Order comment
input bool            InpOnlyGold             = true;            // Only run on gold symbols (XAU / GOLD)
input bool            InpLogSignals           = true;            // Journal: log every signal and why it was not taken

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
input double          InpTesterBrokerGMT      = 2.0;             // Tester: broker GMT offset in winter (live = auto)
input bool            InpTesterUSDST          = true;            // Tester: broker adds +1h during US summer time
input int             InpFallbackCloseHour    = 23;              // Fallback Friday market close hour (server) if unknown
input int             InpFallbackCloseMin     = 55;              // Fallback Friday market close minute (server)
input bool            InpCloseStale           = true;            // Close trades left over from a previous week

input group "=== Market session filter (London / New York) ==="
input bool            InpUseSessionFilter     = true;            // Only enter during the selected sessions
input bool            InpSessLondon           = true;            // London session
input int             InpLondonStartHour      = 8;               // London start hour (London local time)
input int             InpLondonEndHour        = 17;              // London end hour (London local time)
input bool            InpSessNewYork          = true;            // New York session
input int             InpNYStartHour          = 8;               // New York start hour (New York local time)
input int             InpNYEndHour            = 17;              // New York end hour (New York local time)
input bool            InpSessAsia             = false;           // Asian session (Tokyo)
input int             InpAsiaStartHour        = 9;               // Asia start hour (Tokyo local time)
input int             InpAsiaEndHour          = 18;              // Asia end hour (Tokyo local time)

input group "=== High-impact news filter ==="
input bool            InpUseNewsFilter        = true;            // Pause new entries around high-impact news
input string          InpNewsCurrencies       = "USD";           // News currencies (comma separated, e.g. USD,EUR)
input bool            InpNewsIncludeMedium    = false;           // Also pause for medium-impact news
input int             InpNewsMinsBefore       = 30;              // Pause minutes BEFORE the news
input int             InpNewsMinsAfter        = 30;              // Pause minutes AFTER the news
input string          InpNewsKeywords         = "";              // Only events containing (comma separated, empty = all)
input bool            InpNewsNFPRule          = true;            // No calendar (tester): block NFP, 1st Friday 08:30 New York
input string          InpNewsManualTimes      = "";              // Extra news, server time: 2026.11.06 15:30;2026.11.12 15:30

input group "=== HTF trend filter ==="
input ENUM_TREND_MODE InpTrendMode            = TREND_MA;        // Trend filter mode
input ENUM_TIMEFRAMES InpTrendTF              = PERIOD_D1;       // Trend timeframe (D1 or W1)
input int             InpTrendMAPeriod        = 50;              // Trend MA period
input ENUM_MA_METHOD  InpTrendMAMethod        = MODE_EMA;        // Trend MA method
input int             InpTrendSlopeBars       = 5;               // MA must slope over N bars (0 = no slope check)
input int             InpTrendSwingBars       = 3;               // Structure: swing strength (bars each side)
input int             InpTrendLookback        = 150;             // Structure: bars to scan
input bool            InpTrendBlockNeutral    = true;            // No trades when the trend is neutral / mixed

input group "=== D1 liquidity zones (Friday + Monday + Tuesday) ==="
input ENUM_ZONE_MODE  InpZoneMode             = ZONE_PERCENT;    // How to size the sell / buy zones
input double          InpZoneDepthPct         = 25.0;            // Zone depth: % of the 3-day range (percent mode)
input double          InpZoneMinDepthATR      = 0.25;            // Minimum zone depth (x D1 ATR)
input double          InpZoneSweepATR         = 0.35;            // Zone extends beyond the extreme for sweeps (x D1 ATR)
input bool            InpRequireSweep         = false;           // Require the Fri/Mon/Tue high/low to be swept first
input ENUM_POI_MODE   InpEntryPOI             = POI_OB_AND_ZONE; // Where to take entries
input ENUM_SL_MODE    InpZoneSLMode           = SL_M5_CANDLE;    // D1 zone entries: SL beyond the M5 tap (or the zone edge)
input int             InpMaxZoneTradesPerSide = 2;               // D1 zone entries: max per zone side per week (0 = no limit)
input int             InpATRPeriod            = 14;              // ATR period (D1 / H4 / M5)

input group "=== H4 order blocks ==="
input int             InpOBLookback           = 60;              // H4 bars to scan for order blocks
input int             InpOBImpulseBars        = 3;               // Bars allowed for the displacement after the OB candle
input double          InpOBMinImpulseATR      = 1.0;             // Minimum displacement size (x H4 ATR)
input bool            InpOBRequireBOS         = true;            // Displacement must close beyond the OB candle
input int             InpMaxOBsPerSide        = 5;               // Max order blocks tracked per side

input group "=== M5 entry (rejection candle + ChoCH) ==="
input ENUM_ENTRY_CONFIRM InpEntryConfirm      = CONFIRM_REJECTION_CHOCH; // Entry confirmation
input int             InpChochSwingBars       = 2;               // ChoCH: M5 swing strength (bars each side)
input int             InpChochWindow          = 48;              // ChoCH: max M5 bars from OB touch to the break
input int             InpChochSwingLookback   = 30;              // ChoCH: M5 bars searched for the swing before the touch
input bool            InpUsePinBar            = true;            // Pin bar / long-wick rejection candle
input double          InpPinMinWickPct        = 50.0;            // Rejection wick >= % of candle range
input double          InpPinMaxBodyPct        = 40.0;            // Candle body <= % of candle range
input bool            InpUseEngulfing         = true;            // Engulfing rejection candle
input double          InpMinCandleATR         = 0.30;            // Signal candle range >= x M5 ATR
input bool            InpRequireConfirm       = false;           // Rejection-only mode: next M5 candle must break the rejection candle

input group "=== Risk & targets ==="
input ENUM_LOT_MODE   InpLotMode              = LOT_RISK_PERCENT; // Lot sizing mode
input double          InpRiskPercent          = 1.0;             // Total risk per setup in % of balance (both trades)
input double          InpFixedLot             = 0.01;            // Fixed lot per trade (fixed mode)
input double          InpPartialLegPct        = 50.0;            // % of the setup volume on the TP1 (partial) trade
input double          InpMaxRiskPercent       = 3.0;             // Skip if min-lot rounding pushes risk above this %
input double          InpRewardRisk           = 2.0;             // TP2 risk:reward (fixed target / TP1 reference)
input ENUM_TP2_MODE   InpTP2Mode              = TP2_ATR_TRAIL;   // TP2 trade exit
input ENUM_TIMEFRAMES InpTrailTF              = PERIOD_H1;       // Trailing ATR timeframe
input int             InpTrailATRPeriod       = 14;              // Trailing ATR period
input double          InpTrailATRMult         = 2.0;             // Trailing distance (x ATR)
input double          InpTrailStep            = 1.00;            // Minimum SL improvement per trail move (price, $)
input double          InpTrailHardTPRR        = 0.0;             // ATR-trail mode: optional far TP in R (0 = none)
input double          InpMinPartialRR         = 0.5;             // Tuesday 50% must be at least this R away from entry
input double          InpFallbackPartialRR    = 1.0;             // TP1 at this R when the Tuesday 50% is not usable
input ENUM_SL_MODE    InpSLMode               = SL_OB_EXTREME;   // Stop loss placement
input double          InpSLBuffer             = 0.50;            // SL buffer beyond the OB / candle extreme (price, $)
input double          InpMinSL                = 3.00;            // Minimum SL distance (price, $)
input double          InpMaxSL                = 0.0;             // Maximum SL distance (price, $) - 0 = automatic (x D1 ATR)
input double          InpMaxSLATR             = 1.0;             // Automatic maximum SL = x D1 ATR (when max SL = 0)
input bool            InpMoveRunnerToBE       = true;            // Move the TP2 trade to breakeven when TP1 is hit
input double          InpBEOffset             = 0.30;            // Breakeven offset in profit (price, $)
input double          InpMaxSpread            = 0.80;            // Maximum spread allowed for entries (price, $)
input int             InpSlippagePoints       = 30;              // Maximum slippage (points)
input int             InpMaxSetupsPerWeek     = 5;               // Max setups per week (each setup = TP1 trade + TP2 trade)

input group "=== Weekly profit target ==="
input double          InpWeeklyProfitTarget   = 250.0;           // Weekly profit target in account currency (0 = off)
input bool            InpTargetIncludeFloating= true;            // Count open trades' floating P/L toward the target
input bool            InpTargetCloseTrades    = true;            // Close open trades when the target is reached

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
input bool            InpTgNewsAlerts         = true;            // Message when a news pause starts
input bool            InpTgNotifyTrail        = false;           // Message on every trailing stop move
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
   bool              sellZoneOk;     // false once an M5 candle closed above the sell zone
   bool              buyZoneOk;      // false once an M5 candle closed below the buy zone
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

struct SDiag
  {
   int               weeks;          // weeks started
   int               zonesBuilt;     // weeks with D1 zones built
   int               obsFound;       // H4 order blocks mapped
   int               barsWatched;    // M5 bars evaluated with active OB / zone
   int               barsTouch;      // ... where price touched an OB / zone
   int               signals;        // M5 entry signals found
   int               blkTrend;       // signal blocked: HTF trend
   int               blkTime;        // signal blocked: day / hour / Friday cut-off / weekly close
   int               blkSession;     // signal blocked: session filter
   int               blkNews;        // signal blocked: news filter
   int               blkSpread;      // signal blocked: spread
   int               blkSweep;       // signal blocked: liquidity not swept
   int               skipMaxSL;      // signal skipped: SL above the maximum
   int               skipLots;       // signal skipped: lot / risk / margin
   int               failOrder;      // order rejected
   int               opened;         // setups opened
  };

#define DIAG(f) { g_diag.f++; g_diagW.f++; }

struct SNewsEvent
  {
   datetime          time;           // server time
   string            name;
   string            currency;
   bool              high;           // high impact (false = medium)
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
const string   g_pfx     = "LSW_";
const string   g_eaName  = "XAU Liquidity Swing EA";
const string   g_eaVer   = "2.11";

CTrade         g_tradeP;                 // TP1 / partial trade (magic)
CTrade         g_tradeR;                 // TP2 / full trade (magic + 1)
SWeekLiquidity g_week;
SOrderBlock    g_obs[];

long           g_magicP            = 0;
long           g_magicR            = 0;
int            g_hAtrD1            = INVALID_HANDLE;
int            g_hAtrH4            = INVALID_HANDLE;
int            g_hAtrM5            = INVALID_HANDLE;
int            g_hAtrTrail         = INVALID_HANDLE;
int            g_hTrendMA          = INVALID_HANDLE;
SNewsEvent     g_news[];
datetime       g_newsLoaded        = 0;
bool           g_newsCalendarOk    = false;
datetime       g_lastNewsAlert     = 0;
ulong          g_trailTickets[];
int            g_trendDir          = 0;
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
SDiag          g_diag;                   // whole run
SDiag          g_diagW;                  // current week
datetime       g_lastEvalBar       = 0;
string         g_lastBlock         = "";
int            g_zoneSellMem       = 0;
int            g_zoneBuyMem        = 0;
double         g_weekRealized      = 0.0;
bool           g_targetHit         = false;
datetime       g_lastTargetClose   = 0;
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
//| Weekly close time                                                |
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

//+------------------------------------------------------------------+
//| Market session filter (London / New York / Asia)                 |
//+------------------------------------------------------------------+
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

void ComputeCloseTimes(const datetime weekStart)
  {
   long target = (long)weekStart + 5 * 86400 + (long)InpCloseHour * 3600 + (long)InpCloseMinute * 60;
   if(InpCloseTimeZone == CLOSE_TZ_LOCAL)
      target += (long)BrokerOffsetAt((datetime)target) - (long)MathRound(InpLocalGMTOffset * 3600.0);
   g_closeTarget = (datetime)target;
   datetime mkt = (datetime)((long)FridayMarketClose(weekStart) - (long)InpCloseBeforeMarketMin * 60);
   g_closeEffective = (g_closeTarget < mkt) ? g_closeTarget : mkt;
  }

void EnsureWeek(const datetime now)
  {
   if((long)now < 946684800)                 // clock not set yet (before 2000) - wait for a real time
      return;
   datetime ws = WeekStartOf(now);
   if(ws <= g_curWeekStart)
      return;
   if(g_curWeekStart > 0)
      PrintWeekDiag(g_curWeekStart);
   ZeroMemory(g_diagW);
   DIAG(weeks);
   g_curWeekStart      = ws;
   ZeroMemory(g_week);
   ArrayResize(g_obs, 0);
   g_setupsMem         = 0;
   g_zoneSellMem       = 0;
   g_zoneBuyMem        = 0;
   g_lastH4Bar         = 0;
   g_closeFailNotified = false;
   ComputeCloseTimes(ws);
   string gv = GVName("target");
   g_targetHit = GlobalVariableCheck(gv) && (long)GlobalVariableGet(gv) >= (long)ws;
   UpdateWeekRealized();
   g_status = "New week " + TimeToString(ws, TIME_DATE) + ": Fri/Mon/Tue liquidity forming";
  }

//+------------------------------------------------------------------+
//| High-impact news filter                                          |
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

void NewsAlertCheck(const datetime now)
  {
   if(!InpUseNewsFilter || !InpTgNewsAlerts || !InpTelegramEnable)
      return;
   int dow = DowOf(now);
   bool tradeDay = (dow == 3 && InpTradeWednesday) || (dow == 4 && InpTradeThursday) || (dow == 5 && InpTradeFriday);
   if(!tradeDay)
      return;
   int i = BlockingNews(now);
   if(i < 0 || g_news[i].time == g_lastNewsAlert)
      return;
   g_lastNewsAlert = g_news[i].time;
   datetime until = (datetime)((long)g_news[i].time + (long)InpNewsMinsAfter * 60);
   TgSend(E_Warn() + " NEWS PAUSE - " + _Symbol + "\n" + NewsLine(i) + "\n"
          + "No new entries until " + DayTime(until) + " (server). Open trades keep their SL / TP.");
  }

//+------------------------------------------------------------------+
//| HTF trend filter                                                 |
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

//--- D1 zone entries this week on one side (entry deals of the TP1 trade tagged " Z ")
int ZoneTradesThisWeek(const int dir)
  {
   int cnt = 0;
   if(HistorySelect(g_curWeekStart, (datetime)((long)TimeCurrent() + 86400)))
     {
      int total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0)
            continue;
         if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol || HistoryDealGetInteger(d, DEAL_MAGIC) != g_magicP)
            continue;
         if(HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN)
            continue;
         if(StringFind(HistoryDealGetString(d, DEAL_COMMENT), " Z ") < 0)
            continue;
         long type = HistoryDealGetInteger(d, DEAL_TYPE);
         if((dir < 0 && type == DEAL_TYPE_SELL) || (dir > 0 && type == DEAL_TYPE_BUY))
            cnt++;
        }
     }
   int mem = (dir < 0) ? g_zoneSellMem : g_zoneBuyMem;
   return (cnt > mem) ? cnt : mem;
  }

bool ZoneTradeRoom(const int dir)
  {
   if(InpMaxZoneTradesPerSide <= 0)
      return true;
   return (ZoneTradesThisWeek(dir) < InpMaxZoneTradesPerSide);
  }

//+------------------------------------------------------------------+
//| Weekly profit target                                             |
//+------------------------------------------------------------------+
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
   w.sellZoneOk = true;
   w.buyZoneOk  = true;
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
   g_diag.obsFound  += newCount;
   g_diagW.obsFound += newCount;
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

//--- gates that make looking for a signal pointless (no zones, trade running, weekly limits)
bool HardGate(string &why)
  {
   if(!g_week.valid)
     {
      why = "Waiting for D1 zones (built after the Tuesday close)";
      return false;
     }
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
   return true;
  }

//--- filters checked when a signal appears. code: 1 day / hours, 2 session, 3 news, 4 spread
bool SoftGate(const datetime now, string &why, int &code)
  {
   code = 1;
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
   code = 2;
   string sess = "";
   if(!SessionAllows(now, sess))
     {
      why = "Session filter: " + sess;
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
   code = 0;
   return true;
  }

bool CanOpenNewSetup(string &why)
  {
   if(!HardGate(why))
      return false;
   int code = 0;
   return SoftGate(TimeCurrent(), why, code);
  }

//+------------------------------------------------------------------+
//| M5 ChoCH / market structure break after the OB touch             |
//|  SELL: price taps the bearish OB (sweep high), then an M5 candle |
//|        closes below the last swing low formed before the tap.    |
//|  BUY : mirror image. Only the FIRST break after the tap counts.  |
//+------------------------------------------------------------------+
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
   pattern  = "ChoCH: M5 close " + side + P2S(level) + " after the OB tap at " + P2S(sweepExt);

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

//--- entry signal at one point of interest (H4 order block or D1 zone):
//--- fills the SL anchor (candle / structure extreme) and the arrow position.
//--- 'late' = M5 candles closed since the previous check (normally 1)
bool FindEntrySignal(const SOrderBlock &poi, const MqlRates &m5[], const int count, const double atr, const int late,
                     string &pattern, double &ext, datetime &sigTime, double &sigPrice)
  {
   bool isSell = (poi.dir < 0);
   if(InpEntryConfirm == CONFIRM_REJECTION)
     {
      for(int c = 1; c <= late; c++)
        {
         int sig = InpRequireConfirm ? c + 1 : c;
         if(sig + 1 >= count)
            break;
         string pt = "";
         if(!IsRejection(poi, m5, sig, atr, pt))
            continue;
         double e = isSell ? m5[sig].high : m5[sig].low;
         if(InpRequireConfirm)
           {
            if(isSell && !(m5[c].close < m5[sig].low))
               continue;
            if(!isSell && !(m5[c].close > m5[sig].high))
               continue;
            pt += " + confirmation candle";
            e = isSell ? MathMax(e, m5[c].high) : MathMin(e, m5[c].low);
           }
         pattern  = pt;
         ext      = e;
         sigTime  = m5[sig].time;
         sigPrice = e;
         return true;
        }
      return false;
     }
   double sweep = 0.0, level = 0.0;
   int brk = 1;
   if(!CheckChoch(poi, m5, count, atr, late, pattern, sweep, level, brk))
      return false;
   ext      = sweep;
   sigTime  = m5[brk].time;
   sigPrice = isSell ? m5[brk].high : m5[brk].low;
   return true;
  }

void LogSignal(const string tag, const string reason)
  {
   g_lastBlock = reason;
   if(InpLogSignals)
      Print("SIGNAL ", tag, " -> NOT TAKEN: ", reason);
  }

void CheckEntries(void)
  {
   int k    = (InpChochSwingBars > 0) ? InpChochSwingBars : 1;
   int need = InpChochWindow + InpChochSwingLookback + k + 6;
   if(need < 20)
      need = 20;
   MqlRates m5[];
   ArraySetAsSeries(m5, true);
   int count = CopyRates(_Symbol, PERIOD_M5, 0, need, m5);
   if(count < 6)
      return;

   //--- M5 candles closed since the previous check (> 1 when ticks were skipped, e.g. tester 'Open prices only')
   int late = 1;
   if(g_lastEvalBar > 0)
     {
      late = 0;
      for(int s = 1; s < count && m5[s].time > g_lastEvalBar; s++)
         late++;
      if(late < 1)
         late = 1;
      if(late > 12)
         late = 12;
     }
   g_lastEvalBar = m5[1].time;

   for(int s = late; s >= 1; s--)
     {
      //--- an M5 close through an order block invalidates it
      for(int i = 0; i < ArraySize(g_obs); i++)
        {
         if(!g_obs[i].valid)
            continue;
         if((g_obs[i].dir < 0 && m5[s].close > g_obs[i].high) || (g_obs[i].dir > 0 && m5[s].close < g_obs[i].low))
           {
            g_obs[i].valid = false;
            DrawOB(g_obs[i]);
           }
        }
      //--- an M5 close beyond a D1 zone (incl. its sweep allowance) = zone broken for the rest of the week
      if(g_week.valid && g_week.sellZoneOk && m5[s].close > g_week.sellTop)
        {
         g_week.sellZoneOk = false;
         DrawWeek();
         if(InpEntryPOI != POI_OB_ONLY)
            TgSend(E_Warn() + " " + _Symbol + " D1 SELL zone broken (M5 close above " + P2S(g_week.sellTop) + ") - no more sell-zone entries this week");
        }
      if(g_week.valid && g_week.buyZoneOk && m5[s].close < g_week.buyBottom)
        {
         g_week.buyZoneOk = false;
         DrawWeek();
         if(InpEntryPOI != POI_OB_ONLY)
            TgSend(E_Warn() + " " + _Symbol + " D1 BUY zone broken (M5 close below " + P2S(g_week.buyBottom) + ") - no more buy-zone entries this week");
        }
     }

   string why = "";
   if(!HardGate(why))
     {
      g_status = why;
      return;
     }

   //--- points of interest: H4 order blocks first, then the D1 zones themselves
   SOrderBlock poi[];
   int src[];                                // >= 0: index in g_obs, -1: D1 zone
   if(InpEntryPOI != POI_ZONE_ONLY)
      for(int i = 0; i < ArraySize(g_obs); i++)
         if(g_obs[i].valid && !g_obs[i].used)
            PushPOI(poi, src, g_obs[i], i);
   if(InpEntryPOI != POI_OB_ONLY)
     {
      SOrderBlock z;
      if(g_week.sellZoneOk && ZoneTradeRoom(-1))
        {
         MakeZonePOI(-1, z);
         PushPOI(poi, src, z, -1);
        }
      if(g_week.buyZoneOk && ZoneTradeRoom(+1))
        {
         MakeZonePOI(+1, z);
         PushPOI(poi, src, z, -1);
        }
     }
   int active = ArraySize(poi);
   if(active == 0)
     {
      g_status = "Watching: no active H4 order block / D1 zone";
      return;
     }
   DIAG(barsWatched);
   bool touched = false;
   for(int i = 0; i < active && !touched; i++)
      for(int s = 1; s <= late && !touched; s++)
         if(m5[s].high >= poi[i].low && m5[s].low <= poi[i].high)
            touched = true;
   if(touched)
      DIAG(barsTouch);

   double atrM5 = GetATR(g_hAtrM5, 1);
   if(atrM5 <= 0)
      atrM5 = m5[1].high - m5[1].low;
   g_trendDir = TrendDir();
   string softWhy = "";
   int softCode = 0;
   bool softOk = SoftGate(TimeCurrent(), softWhy, softCode);
   string confirmTxt = (InpEntryConfirm == CONFIRM_REJECTION) ? "rejection candle"
                       : (InpEntryConfirm == CONFIRM_CHOCH ? "ChoCH" : "rejection + ChoCH");
   if(softOk)
      g_status = "Watching " + IntegerToString(active) + " H4 OB / D1 zone(s) for an M5 " + confirmTxt;
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
      if(!FindEntrySignal(poi[i], m5, count, atrM5, late, pattern, ext, sigTime, sigPrice))
         continue;
      bool isZone = (src[i] < 0);
      string where = isZone ? " at D1 zone " : " at H4 OB ";
      string tag = DirText(poi[i].dir < 0) + where + P2S(poi[i].low) + "-" + P2S(poi[i].high) + " [" + pattern + "]";
      DIAG(signals);
      if(!TrendAllows(poi[i].dir, g_trendDir))
        {
         DIAG(blkTrend);
         LogSignal(tag, "HTF trend " + TrendText(g_trendDir));
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
         LogSignal(tag, softWhy);
         blockedDirs |= bit;
         continue;
        }
      if(InpRequireSweep && !LiquiditySwept(poi[i].dir))
        {
         DIAG(blkSweep);
         LogSignal(tag, "the Fri/Mon/Tue liquidity is not swept yet");
         blockedDirs |= bit;
         continue;
        }
      string skip = "";
      int code = 0;
      int res = OpenSetup(poi[i], isZone, ext, sigTime, sigPrice, pattern, skip, code);
      if(res > 0)
        {
         DIAG(opened);
         if(isZone)
           {
            if(poi[i].dir < 0)
               g_zoneSellMem++;
            else
               g_zoneBuyMem++;
           }
         else
           {
            g_obs[src[i]].used = true;
            DrawOB(g_obs[src[i]]);
           }
         break;
        }
      if(code == 1)
         DIAG(skipMaxSL);
      if(code == 2)
         DIAG(skipLots);
      if(code == 3)
         DIAG(failOrder);
      LogSignal(tag, skip);
      if(res < 0 && !isZone)
        {
         g_obs[src[i]].used = true;          // skipped for good (lot / risk limits)
         DrawOB(g_obs[src[i]]);
        }
     }
  }

void PushPOI(SOrderBlock &arr[], int &src[], const SOrderBlock &p, const int from)
  {
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   ArrayResize(src, n + 1);
   arr[n] = p;
   src[n] = from;
  }

//--- the D1 sell / buy zone as a point of interest
void MakeZonePOI(const int dir, SOrderBlock &z)
  {
   z.time  = g_week.weekStart;
   z.dir   = dir;
   z.high  = (dir < 0) ? g_week.sellTop : g_week.buyTop;
   z.low   = (dir < 0) ? g_week.sellBottom : g_week.buyBottom;
   z.valid = true;
   z.used  = false;
  }

//+------------------------------------------------------------------+
//| Max SL + diagnostics (why trades were / were not taken)          |
//+------------------------------------------------------------------+
double MaxSLPrice(void)
  {
   double m = InpMaxSL;
   if(m <= 0)
     {
      double atr = (g_week.atrD1 > 0) ? g_week.atrD1 : GetATR(g_hAtrD1, 1);
      m = (atr > 0) ? InpMaxSLATR * atr : 60.0;
     }
   return (m > InpMinSL) ? m : InpMinSL + 1.0;
  }

string DiagLine(const SDiag &d)
  {
   return "zones " + IntegerToString(d.zonesBuilt) + " | H4 OBs " + IntegerToString(d.obsFound)
          + " | M5 bars at OB/zone " + IntegerToString(d.barsTouch) + "/" + IntegerToString(d.barsWatched)
          + " | signals " + IntegerToString(d.signals) + " -> opened " + IntegerToString(d.opened)
          + " (trend " + IntegerToString(d.blkTrend) + ", session " + IntegerToString(d.blkSession)
          + ", news " + IntegerToString(d.blkNews) + ", day/time " + IntegerToString(d.blkTime)
          + ", spread " + IntegerToString(d.blkSpread) + ", sweep " + IntegerToString(d.blkSweep)
          + ", SL>max " + IntegerToString(d.skipMaxSL) + ", lot/risk " + IntegerToString(d.skipLots)
          + ", order failed " + IntegerToString(d.failOrder) + ")";
  }

void PrintWeekDiag(const datetime ws)
  {
   Print("WEEK ", TimeToString(ws, TIME_DATE), ": ", DiagLine(g_diagW));
  }

string DiagReportText(void)
  {
   SDiag d;
   d = g_diag;
   string s = E_Chart() + " " + g_eaName + " v" + g_eaVer + " - DIAGNOSTICS (" + _Symbol + ")\n";
   s += "Weeks: " + IntegerToString(d.weeks) + " | D1 zones built: " + IntegerToString(d.zonesBuilt)
        + " | H4 order blocks: " + IntegerToString(d.obsFound) + "\n";
   s += "M5 bars watched (Wed-Fri, zones ready, no trade open): " + IntegerToString(d.barsWatched)
        + " | price at an OB / zone: " + IntegerToString(d.barsTouch) + "\n";
   s += "Entry signals (" + ConfirmModeText() + "): " + IntegerToString(d.signals) + "\n";
   s += "  blocked by HTF trend: " + IntegerToString(d.blkTrend) + "\n";
   s += "  blocked by session filter: " + IntegerToString(d.blkSession) + "\n";
   s += "  blocked by news filter: " + IntegerToString(d.blkNews) + "\n";
   s += "  blocked by day / hours / Friday cut-off: " + IntegerToString(d.blkTime) + "\n";
   s += "  blocked by spread: " + IntegerToString(d.blkSpread) + "\n";
   s += "  blocked by liquidity-sweep rule: " + IntegerToString(d.blkSweep) + "\n";
   s += "  skipped - SL above maximum: " + IntegerToString(d.skipMaxSL) + "\n";
   s += "  skipped - lot / risk / margin: " + IntegerToString(d.skipLots) + "\n";
   s += "  order rejected: " + IntegerToString(d.failOrder) + "\n";
   s += "Setups opened: " + IntegerToString(d.opened) + "\n";
   //--- tips for the biggest blocker
   string tip = "";
   if(d.weeks < 2)
      tip = "Test a longer period (at least 2-3 months): the EA only trades Wed / Thu / Fri after the Tuesday D1 close.";
   else
      if(d.zonesBuilt == 0)
         tip = "D1 zones were never built: not enough D1 history for the test start.";
      else
         if(d.barsTouch == 0)
            tip = "Price never reached an H4 order block / D1 zone on Wed-Fri: raise 'Zone depth %' or 'Zone extends beyond the extreme'.";
         else
            if(d.signals == 0)
               tip = "Price reached the zones but the M5 confirmation never formed: set 'Entry confirmation' = 'M5 ChoCH only' or 'Rejection candle only', or raise the ChoCH window.";
   if(tip == "" && d.opened == 0 && d.signals > 0)
     {
      int mx = d.blkTrend;
      tip = "Most signals were against the HTF trend: set 'Trend filter mode' = Off, or 'No trades when the trend is neutral' = false.";
      if(d.blkSession > mx)
        {
         mx = d.blkSession;
         tip = "Most signals were outside London / New York: set 'Only enter during the selected sessions' = false or add the Asian session.";
        }
      if(d.blkNews > mx)
        {
         mx = d.blkNews;
         tip = "Most signals were inside a news pause: lower the news minutes or switch the news filter off.";
        }
      if(d.blkTime > mx)
        {
         mx = d.blkTime;
         tip = "Most signals were outside the entry days / hours: check 'Entry window' and 'Friday: no new entries from this hour'.";
        }
      if(d.blkSpread > mx)
        {
         mx = d.blkSpread;
         tip = "Most signals had a too-wide spread: raise 'Maximum spread' (the tester uses your broker's spread).";
        }
      if(d.skipMaxSL > mx)
        {
         mx = d.skipMaxSL;
         tip = "Most signals needed a stop wider than the maximum: raise 'Maximum SL' or 'Automatic maximum SL = x D1 ATR'.";
        }
      if(d.skipLots > mx)
        {
         mx = d.skipLots;
         tip = "The deposit is too small for 2 x minimum lot at this stop: raise the tester deposit, 'Max risk %', or use Lot mode = Fixed.";
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

string POIText(void)
  {
   if(InpEntryPOI == POI_OB_ONLY)
      return "H4 order blocks";
   if(InpEntryPOI == POI_ZONE_ONLY)
      return "D1 zones";
   return "H4 order blocks + D1 zones";
  }

string ConfirmModeText(void)
  {
   if(InpEntryConfirm == CONFIRM_REJECTION)
      return "M5 rejection candle";
   if(InpEntryConfirm == CONFIRM_CHOCH)
      return "M5 ChoCH";
   return "M5 rejection + ChoCH";
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

//--- returns 1 = opened, 0 = not opened (retry on a later signal), -1 = skipped for good (lot / risk limits)
int OpenSetup(const SOrderBlock &poi, const bool isZone, const double candleExt, const datetime sigTime,
              const double sigPrice, const string pattern, string &skipWhy, int &skipCode)
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
   double spread = tick.ask - tick.bid;
   double entry  = isSell ? tick.bid : tick.ask;

   //--- stop loss: beyond the H4 OB / D1 zone edge (or the M5 rejection candle / ChoCH tap) + buffer
   ENUM_SL_MODE slMode = isZone ? InpZoneSLMode : InpSLMode;
   double ext = candleExt;
   if(slMode == SL_OB_EXTREME)
      ext = isSell ? MathMax(poi.high, candleExt) : MathMin(poi.low, candleExt);
   double sl      = isSell ? ext + InpSLBuffer + spread : ext - InpSLBuffer;
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
      skipWhy  = "SL " + P2S(risk) + " > max " + P2S(maxSL) + " (raise 'Maximum SL' / the D1 ATR multiple)";
      skipCode = 1;
      g_status = DirText(isSell) + " signal skipped: " + skipWhy;
      return 0;
     }

   //--- targets: TP1 = Tuesday 50% (partial), TP2 = 1:RR and / or ATR trailing stop
   double fullDist = InpRewardRisk * risk;
   double tp2 = isSell ? entry - fullDist : entry + fullDist;
   string tp2Txt = "1:" + DoubleToString(InpRewardRisk, 1);
   if(InpTP2Mode == TP2_ATR_TRAIL)
     {
      tp2 = 0.0;
      tp2Txt = "no fixed TP - ATR trailing stop after TP1 (" + TrailText() + ")";
      if(InpTrailHardTPRR > 0)
        {
         tp2 = isSell ? entry - InpTrailHardTPRR * risk : entry + InpTrailHardTPRR * risk;
         tp2Txt = "ATR trailing stop after TP1 (" + TrailText() + "), far TP 1:" + DoubleToString(InpTrailHardTPRR, 1);
        }
     }
   else
      if(InpTP2Mode == TP2_RR_PLUS_TRAIL)
         tp2Txt += " + ATR trailing stop after TP1 (" + TrailText() + ")";
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
      tp1Src = DoubleToString(r, 1) + "R fallback - Tuesday 50% not between entry and 1:" + DoubleToString(InpRewardRisk, 1);
     }
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
      TgSend(E_Warn() + " " + _Symbol + " " + DirText(isSell) + " signal skipped: " + err);
      return -1;                             // caller stops retrying this order block
     }

   //--- send the 2 trades (hedging) or 1 trade + EA-managed partial (netting)
   ulong tP = 0, tR = 0;
   bool okP = false, okR = false;
   string warn = "";
   string tag  = isZone ? " Z" : "";          // " Z " in the comment marks a D1 zone entry
   if(g_netting)
     {
      double total = FloorLot(lotP + lotR);
      okP = SendMarket(g_tradeP, isSell, total, sl, tp2, InpComment + tag + " TP2", tP);
      if(okP)
        {
         GlobalVariableSet(GVName("vtp1"), tp1);
         GlobalVariableSet(GVName("vtp1vol"), lotP);
         GlobalVariableSet(GVName("vtp1done"), 0.0);
        }
     }
   else
     {
      okP = SendMarket(g_tradeP, isSell, lotP, sl, tp1, InpComment + tag + " TP1", tP);
      okR = SendMarket(g_tradeR, isSell, lotR, sl, tp2, InpComment + tag + " TP2", tR);
      if(okP != okR)
        {
         string which = okP ? "TP1 partial" : "TP2 full";
         warn = "\n" + E_Warn() + " Only the " + which + " trade could be opened.";
        }
     }
   if(!okP && !okR)
     {
      g_status = "Order failed: " + g_tradeP.ResultRetcodeDescription();
      skipWhy  = "order rejected by the server: " + g_tradeP.ResultRetcodeDescription();
      skipCode = 3;
      TgSend(E_X() + " " + _Symbol + " " + DirText(isSell) + " entry FAILED: " + g_tradeP.ResultRetcodeDescription());
      return 0;
     }
   g_setupsMem++;

   double fill = okP ? g_tradeP.ResultPrice() : g_tradeR.ResultPrice();
   if(fill <= 0)
      fill = entry;
   double rr1 = (risk > 0) ? MathAbs(tp1 - entry) / risk : 0.0;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskPct = (bal > 0) ? riskMoney / bal * 100.0 : 0.0;

   DrawSignal(isSell, sigTime, sigPrice);

   string tp2Price = (tp2 > 0) ? P2S(tp2) : "trailing";
   string legs = "";
   if(g_netting)
      legs = E_Yellow() + " TP1 partial: " + P2S(tp1) + " (" + tp1Src + ", " + DoubleToString(rr1, 2) + "R) - EA closes " + L2S(lotP) + " lot\n"
             + E_Target() + " TP2: " + tp2Price + " (" + tp2Txt + ") - total " + L2S(FloorLot(lotP + lotR)) + " lot\n";
   else
      legs = E_Yellow() + " Trade 1 TP1 partial: " + P2S(tp1) + " (" + tp1Src + ", " + DoubleToString(rr1, 2) + "R) | " + L2S(lotP) + " lot\n"
             + E_Target() + " Trade 2 TP2: " + tp2Price + " (" + tp2Txt + ") | " + L2S(lotR) + " lot\n";

   string sess = "";
   SessionAllows(TimeCurrent(), sess);
   string poiTxt = isZone ? "Entry at the D1 " + DirText(isSell) + " zone " + P2S(poi.low) + " - " + P2S(poi.high) + " (direct zone entry)"
                   : "Entry at the H4 OB " + P2S(poi.low) + " - " + P2S(poi.high) + " in the D1 " + DirText(isSell) + " zone";
   string msg = (isSell ? E_Down() : E_Up()) + " " + DirText(isSell) + " SETUP OPENED - " + _Symbol + "\n"
                + "Signal: M5 " + pattern + "\n"
                + poiTxt + "\n"
                + "Setup " + IntegerToString(SetupsThisWeek()) + "/" + IntegerToString(InpMaxSetupsPerWeek) + " this week | week P/L " + TargetText() + "\n"
                + "Filters: trend " + TrendText(g_trendDir) + " | session " + sess + " | news clear\n"
                + "Entry: " + P2S(fill) + "\n"
                + E_Stop() + " SL: " + P2S(sl) + " (" + P2S(risk) + " away)\n"
                + legs
                + "Risk: " + M2S(riskMoney) + " " + Currency() + " (" + DoubleToString(riskPct, 2) + "%)\n"
                + E_Clock() + " Held until TP / SL or the weekly close " + DayTime(g_closeEffective) + " (server)"
                + warn;
   Print(DirText(isSell), " setup opened: entry ", P2S(fill), " SL ", P2S(sl), " TP1 ", P2S(tp1), " TP2 ", tp2Price);
   TgSend(msg);
   TgSendScreenshot(_Symbol + " " + DirText(isSell) + " entry @ " + P2S(fill) + " | SL " + P2S(sl) + " | TP1 " + P2S(tp1) + " | TP2 " + tp2Price);
   g_status = DirText(isSell) + " setup running - holding until TP / SL or weekly close";
   return 1;
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
   color sellFill = g_week.sellZoneOk ? InpSellZoneColor : C'45,45,52';
   color buyFill  = g_week.buyZoneOk ? InpBuyZoneColor : C'45,45,52';
   string sellSt  = g_week.sellZoneOk ? "" : " - BROKEN";
   string buySt   = g_week.buyZoneOk ? "" : " - BROKEN";
   DrawRect(p + "SELLZONE", tStart, g_week.sellTop, tEnd, g_week.sellBottom, sellFill, true, 1, STYLE_SOLID, true);
   DrawRect(p + "BUYZONE", tStart, g_week.buyTop, tEnd, g_week.buyBottom, buyFill, true, 1, STYLE_SOLID, true);
   DrawLabel(p + "SELLZONE_T", tWed, g_week.sellTop, "SELL ZONE (D1 liquidity high)  " + P2S(g_week.sellBottom) + " - " + P2S(g_week.sellTop) + sellSt,
             InpLiqHighColor, ANCHOR_LEFT_LOWER);
   DrawLabel(p + "BUYZONE_T", tWed, g_week.buyBottom, "BUY ZONE (D1 liquidity low)  " + P2S(g_week.buyBottom) + " - " + P2S(g_week.buyTop) + buySt,
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

   g_trendDir = TrendDir();
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
   PushLine(L, "Week target: " + TargetText());
   PushLine(L, "Weekly close " + DayTime(g_closeEffective));
   string sess = "";
   string sState = SessionAllows(now, sess) ? "OPEN " : "CLOSED ";
   int ni = BlockingNews(now);
   string news = (!InpUseNewsFilter) ? "off" : (ni >= 0 ? "PAUSED " + StringSubstr(g_news[ni].name, 0, 30) : "clear");
   PushLine(L, "Session: " + sState + StringSubstr(sess, 0, 40));
   PushLine(L, "News: " + news);
   PushLine(L, "HTF trend: " + TrendText(g_trendDir));
   PushLine(L, "Entry: " + ConfirmModeText() + " | TP2: " + StringSubstr(TP2ModeText(), 0, 30));
   PushLine(L, "Signals " + IntegerToString(g_diag.signals) + " | opened " + IntegerToString(g_diag.opened)
            + (g_lastBlock != "" ? " | last block: " + StringSubstr(g_lastBlock, 0, 32) : ""));
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
          + "/news - upcoming high-impact news (48h)\n"
          + "/diag - why trades were / were not taken\n"
          + "/chart - chart screenshot\n"
          + "/help - this list";
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
   s += E_Target() + " TP2 trade: " + TP2ModeText() + "\n";
   s += OBListText();
   s += FiltersStatusText(ServerNow());
   s += "High-impact news this week:\n" + UpcomingNewsText(ServerNow(), 96);
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
   s += FiltersStatusText(now);
   s += "Setups this week: " + IntegerToString(SetupsThisWeek()) + "/" + IntegerToString(InpMaxSetupsPerWeek) + "\n";
   s += "Weekly profit target: " + TargetText() + "\n";
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
   s += "Weekly profit target: " + TargetText() + "\n";
   s += "Open trades:\n" + OpenPositionsText();
   s += "Balance: " + M2S(AccountInfoDouble(ACCOUNT_BALANCE)) + " | Equity: " + M2S(AccountInfoDouble(ACCOUNT_EQUITY)) + "\n";
   s += "Next 24h high-impact news:\n" + UpcomingNewsText(ServerNow(), 24);
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
   if(InpWeeklyProfitTarget > 0)
     {
      string reached = (w.net >= InpWeeklyProfitTarget || g_targetHit) ? "REACHED" : "not reached";
      s += "Weekly profit target " + M2S(InpWeeklyProfitTarget) + " " + Currency() + ": " + reached + "\n";
     }
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
   DIAG(zonesBuilt);
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
   RefreshNews(now);
   NewsAlertCheck(now);
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
               if(InpMaxSetupsPerWeek < 1 || InpWeeklyProfitTarget < 0 || InpMaxZoneTradesPerSide < 0)
                  e = "Setups per week must be >= 1, profit target and zone trades >= 0";
               else
                  if(InpCloseHour < 0 || InpCloseHour > 23 || InpCloseMinute < 0 || InpCloseMinute > 59)
                     e = "Weekly close time is invalid";
                  else
                     if((InpMaxSL > 0 && InpMaxSL <= InpMinSL) || (InpMaxSL <= 0 && InpMaxSLATR <= 0))
                        e = "Max SL must be greater than min SL (or 0 with a positive D1 ATR multiple)";
                     else
                        if(InpOBLookback < 5 || InpOBImpulseBars < 1 || InpMaxOBsPerSide < 1)
                           e = "Order block settings are invalid";
                        else
                           if(InpZoneDepthPct <= 0 || InpZoneDepthPct >= 50)
                              e = "Zone depth % must be between 0 and 50";
                           else
                              if(InpATRPeriod < 2)
                                 e = "ATR period must be >= 2";
   if(e == "" && InpTP2Mode != TP2_FIXED_RR && (InpTrailATRPeriod < 2 || InpTrailATRMult <= 0 || InpTrailStep < 0))
      e = "Trailing stop settings are invalid";
   if(e == "" && InpTrendMode != TREND_OFF && (InpTrendMAPeriod < 2 || InpTrendLookback < 20 || InpTrendSwingBars < 1))
      e = "Trend filter settings are invalid";
   if(e == "" && InpEntryConfirm != CONFIRM_REJECTION && (InpChochSwingBars < 1 || InpChochWindow < 1 || InpChochSwingLookback < 3))
      e = "ChoCH settings are invalid";
   if(e == "" && InpUseNewsFilter && (InpNewsMinsBefore < 0 || InpNewsMinsAfter < 0))
      e = "News minutes must be >= 0";
   if(e == "" && (InpLondonStartHour < 0 || InpLondonStartHour > 24 || InpLondonEndHour < 0 || InpLondonEndHour > 24 ||
                  InpNYStartHour < 0 || InpNYStartHour > 24 || InpNYEndHour < 0 || InpNYEndHour > 24 ||
                  InpAsiaStartHour < 0 || InpAsiaStartHour > 24 || InpAsiaEndHour < 0 || InpAsiaEndHour > 24))
      e = "Session hours must be between 0 and 24";
   if(e == "" && InpUseSessionFilter && !InpSessLondon && !InpSessNewYork && !InpSessAsia)
      e = "Session filter is on but no session is selected";
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
         Print(g_eaName, ": failed to create the trend MA handle, error ", GetLastError());
         return INIT_FAILED;
        }
     }
   ArrayResize(g_trailTickets, 0);
   ArrayResize(g_news, 0);
   g_newsLoaded = 0;

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
   g_lastEvalBar  = 0;
   g_lastBlock    = "";
   ZeroMemory(g_diag);
   ZeroMemory(g_diagW);
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
                + "Risk: " + risk + " | TP1 Tuesday 50% + TP2 " + TP2ModeText() + "\n"
                + "Entry: " + ConfirmModeText() + " | Trend filter: " + TrendText(TrendDir()) + "\n"
                + "Sessions: " + SessionSetupText() + " | News filter: " + (InpUseNewsFilter ? IntegerToString(InpNewsMinsBefore)
                      + "/" + IntegerToString(InpNewsMinsAfter) + " min" : "off") + "\n"
                + "Entries: Wed / Thu / Fri at " + POIText() + " | max " + IntegerToString(InpMaxSetupsPerWeek) + " setups / week\n"
                + "Weekly profit target: " + TargetText() + " | Weekly close " + DayTime(g_closeEffective) + " (server)\n"
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
   if(g_curWeekStart > 0)
      PrintWeekDiag(g_curWeekStart);
   PrintDiagReport();
   if(g_hAtrD1 != INVALID_HANDLE)
      IndicatorRelease(g_hAtrD1);
   if(g_hAtrH4 != INVALID_HANDLE)
      IndicatorRelease(g_hAtrH4);
   if(g_hAtrM5 != INVALID_HANDLE)
      IndicatorRelease(g_hAtrM5);
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
   CheckWeeklyTarget();

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
      UpdateWeekRealized();
      ManageRunners();
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
        {
         bool runner = (magic == g_magicR || g_netting);
         if(profit > 0 && runner && InpTP2Mode != TP2_FIXED_RR)
            title = E_Target() + " TRAILING STOP HIT - profit locked on the TP2 trade";
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
                  title = E_Yellow() + " TP1 HIT - partial closed at the Tuesday 50%";
               else
                  title = E_Clock() + " " + (g_lastCloseReason != "" ? g_lastCloseReason : "Closed by the EA");
              }
            else
               title = E_Warn() + " Closed manually / externally";

   string runnerName = (InpTP2Mode == TP2_ATR_TRAIL) ? "Trade 2 (ATR trailing)" : "Trade 2 (TP2 full)";
   string leg = tp1Leg ? "Trade 1 (TP1 partial)" : (magic == g_magicR ? runnerName : "Position");
   string msg = title + "\n"
                + _Symbol + " " + leg + " | " + L2S(vol) + " lot @ " + P2S(price) + "\n"
                + "Result: " + SignedMoney(profit) + " " + Currency() + "\n"
                + "Balance: " + M2S(AccountInfoDouble(ACCOUNT_BALANCE)) + " | Equity: " + M2S(AccountInfoDouble(ACCOUNT_EQUITY));
   Print(_Symbol, " ", leg, " closed @ ", P2S(price), " result ", SignedMoney(profit));
   TgSend(msg);

   UpdateWeekRealized();
   CheckWeeklyTarget();
   ManageRunners();
   UpdatePanel();
  }
//+------------------------------------------------------------------+
