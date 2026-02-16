#property strict
#property version   "1.00"
#property description "Multi-symbol volatility compression breakout EA for MT5"

input string SymbolsList = "EURUSD,GBPUSD,USDJPY,USDCHF,USDCAD,AUDUSD,NZDUSD,XAUUSD,GER40,US30";
input double RiskPercent = 0.5;
input double MinimumATR = 0.0002;
input int    LookbackBars = 20;
input int    MaxTradeBars = 120;
input int    TimerSeconds = 10;
input int    SlippagePoints = 20;
input ulong  MagicNumber = 20260216;

#define ATR_SHORT_PERIOD 14
#define ATR_LONG_PERIOD  100
#define ATR_COMPRESSION_FACTOR 0.6
#define SPREAD_ATR_FACTOR 0.25
#define SL_ATR_MULTIPLIER 1.2
#define TP_ATR_MULTIPLIER 2.5
#define TRAIL_ACTIVATE_ATR 1.0
#define TRAIL_DISTANCE_ATR 1.0
#define RETRY_COUNT 5

struct SymbolContext
{
   string symbol;
   int atrShortHandle;
   int atrLongHandle;
   datetime lastProcessedBarTime;
};

SymbolContext g_symbols[];

int ParseSymbols(const string list, string &out[])
{
   string parts[];
   int count = StringSplit(list, ',', parts);
   if(count <= 0)
      return 0;

   ArrayResize(out, 0);
   for(int i = 0; i < count; i++)
   {
      string s = parts[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      if(StringLen(s) == 0)
         continue;

      bool exists = false;
      for(int j = 0; j < ArraySize(out); j++)
      {
         if(out[j] == s)
         {
            exists = true;
            break;
         }
      }
      if(!exists)
      {
         int n = ArraySize(out);
         ArrayResize(out, n + 1);
         out[n] = s;
      }
   }
   return ArraySize(out);
}

bool EnsureSymbolReady(const string symbol)
{
   if(!SymbolSelect(symbol, true))
      return false;

   long tradeMode = SYMBOL_TRADE_MODE_DISABLED;
   if(!SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE, tradeMode))
      return false;
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED)
      return false;

   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick))
      return false;
   if(tick.bid <= 0.0 || tick.ask <= 0.0)
      return false;

   return true;
}

bool GetATR(const int handle, double &value)
{
   value = 0.0;
   if(handle == INVALID_HANDLE)
      return false;

   double buf[];
   ArraySetAsSeries(buf, true);
   int copied = CopyBuffer(handle, 0, 0, 3, buf);
   if(copied < 1)
      return false;

   value = buf[0];
   if(value <= 0.0)
      return false;
   return true;
}

bool HasOpenPosition(const string symbol)
{
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;

      string ps = PositionGetString(POSITION_SYMBOL);
      long mg = PositionGetInteger(POSITION_MAGIC);
      if(ps == symbol && (ulong)mg == MagicNumber)
         return true;
   }
   return false;
}

bool GetPendingStops(const string symbol, bool &hasBuyStop, ulong &buyTicket, bool &hasSellStop, ulong &sellTicket)
{
   hasBuyStop = false;
   hasSellStop = false;
   buyTicket = 0;
   sellTicket = 0;

   int total = OrdersTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(!OrderSelect(ticket))
         continue;

      string os = OrderGetString(ORDER_SYMBOL);
      long mg = OrderGetInteger(ORDER_MAGIC);
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(os != symbol || (ulong)mg != MagicNumber)
         continue;

      if(type == ORDER_TYPE_BUY_STOP)
      {
         hasBuyStop = true;
         buyTicket = ticket;
      }
      else if(type == ORDER_TYPE_SELL_STOP)
      {
         hasSellStop = true;
         sellTicket = ticket;
      }
   }

   return true;
}

bool IsTradeEnvironmentSafe(const string symbol, const double atrShort)
{
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick))
      return false;

   double spread = tick.ask - tick.bid;
   if(spread <= 0.0)
      return false;

   if(spread > (atrShort * SPREAD_ATR_FACTOR))
      return false;

   double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(marginLevel > 0.0 && marginLevel < 500.0)
      return false;

   return true;
}

bool GetBreakoutLevels(const string symbol, double &buyStopPrice, double &sellStopPrice)
{
   buyStopPrice = 0.0;
   sellStopPrice = 0.0;

   int needed = MathMax(LookbackBars + 2, 30);
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(symbol, PERIOD_M5, 0, needed, rates);
   if(copied < LookbackBars + 2)
      return false;

   double highest = -DBL_MAX;
   double lowest = DBL_MAX;

   for(int i = 1; i <= LookbackBars; i++)
   {
      if(rates[i].high > highest)
         highest = rates[i].high;
      if(rates[i].low < lowest)
         lowest = rates[i].low;
   }

   if(highest <= 0.0 || lowest <= 0.0 || highest <= lowest)
      return false;

   buyStopPrice = highest;
   sellStopPrice = lowest;
   return true;
}

double NormalizeVolumeByStep(const string symbol, const double volume)
{
   double volMin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double volMax = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double volStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(volStep <= 0.0)
      volStep = volMin;
   if(volMin <= 0.0 || volMax <= 0.0)
      return 0.0;

   double v = MathMax(volMin, MathMin(volMax, volume));
   v = MathFloor(v / volStep) * volStep;
   v = MathMax(volMin, MathMin(volMax, v));

   int volDigits = 2;
   if(volStep > 0.0)
   {
      volDigits = (int)MathRound(-MathLog10(volStep));
      if(volDigits < 0)
         volDigits = 0;
      if(volDigits > 8)
         volDigits = 8;
   }
   return NormalizeDouble(v, volDigits);
}

double CalculateRiskVolume(const string symbol, const double slDistancePrice)
{
   if(slDistancePrice <= 0.0)
      return 0.0;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (RiskPercent / 100.0);
   if(riskMoney <= 0.0)
      return 0.0;

   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValueLoss = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);

   if(tickValueLoss <= 0.0)
      tickValueLoss = tickValue;
   if(tickSize <= 0.0 || tickValueLoss <= 0.0)
      return 0.0;

   double lossPerLot = (slDistancePrice / tickSize) * tickValueLoss;
   if(lossPerLot <= 0.0)
      return 0.0;

   double rawVol = riskMoney / lossPerLot;
   return NormalizeVolumeByStep(symbol, rawVol);
}

bool SendRequestWithRetry(MqlTradeRequest &request, MqlTradeResult &result)
{
   for(int attempt = 0; attempt < RETRY_COUNT; attempt++)
   {
      ResetLastError();
      ZeroMemory(result);
      bool sent = OrderSend(request, result);

      if(sent && (result.retcode == TRADE_RETCODE_DONE ||
                  result.retcode == TRADE_RETCODE_PLACED ||
                  result.retcode == TRADE_RETCODE_DONE_PARTIAL))
      {
         return true;
      }

      int ret = (int)result.retcode;
      if(ret == TRADE_RETCODE_REQUOTE ||
         ret == TRADE_RETCODE_PRICE_CHANGED ||
         ret == TRADE_RETCODE_PRICE_OFF ||
         ret == TRADE_RETCODE_TOO_MANY_REQUESTS ||
         ret == TRADE_RETCODE_CONNECTION ||
         ret == TRADE_RETCODE_TIMEOUT ||
         ret == TRADE_RETCODE_LOCKED)
      {
         Sleep(200 + attempt * 200);
         continue;
      }

      break;
   }

   return false;
}

bool PlaceStopOrder(const string symbol,
                    const ENUM_ORDER_TYPE orderType,
                    const double volume,
                    const double price,
                    const double sl,
                    const double tp)
{
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   request.action = TRADE_ACTION_PENDING;
   request.symbol = symbol;
   request.magic = MagicNumber;
   request.volume = volume;
   request.type = orderType;
   request.price = NormalizeDouble(price, digits);
   request.sl = NormalizeDouble(sl, digits);
   request.tp = NormalizeDouble(tp, digits);
   request.type_filling = ORDER_FILLING_RETURN;
   request.type_time = ORDER_TIME_GTC;
   request.deviation = SlippagePoints;
   request.comment = "VCB";

   return SendRequestWithRetry(request, result);
}

bool DeleteOrder(const ulong ticket)
{
   if(ticket == 0)
      return false;

   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action = TRADE_ACTION_REMOVE;
   request.order = ticket;

   return SendRequestWithRetry(request, result);
}

bool ModifyPositionSLTP(const ulong ticket, const string symbol, const double newSL, const double newTP)
{
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol = symbol;
   request.magic = MagicNumber;
   request.sl = newSL;
   request.tp = newTP;

   return SendRequestWithRetry(request, result);
}

bool ClosePositionByTicket(const ulong ticket, const string symbol, const ENUM_POSITION_TYPE type, const double volume)
{
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick))
      return false;

   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action = TRADE_ACTION_DEAL;
   request.position = ticket;
   request.symbol = symbol;
   request.magic = MagicNumber;
   request.volume = volume;
   request.deviation = SlippagePoints;
   request.type_filling = ORDER_FILLING_IOC;

   if(type == POSITION_TYPE_BUY)
   {
      request.type = ORDER_TYPE_SELL;
      request.price = tick.bid;
   }
   else if(type == POSITION_TYPE_SELL)
   {
      request.type = ORDER_TYPE_BUY;
      request.price = tick.ask;
   }
   else
   {
      return false;
   }

   return SendRequestWithRetry(request, result);
}

void ManagePendingPair(const string symbol)
{
   bool hasBuyStop, hasSellStop;
   ulong buyTicket, sellTicket;
   GetPendingStops(symbol, hasBuyStop, buyTicket, hasSellStop, sellTicket);

   bool hasPos = HasOpenPosition(symbol);
   if(!hasPos)
      return;

   if(hasBuyStop && hasSellStop)
   {
      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)-1;
      bool found = false;

      int total = PositionsTotal();
      for(int i = total - 1; i >= 0; i--)
      {
         ulong pticket = PositionGetTicket(i);
         if(pticket == 0)
            continue;
         if(!PositionSelectByTicket(pticket))
            continue;

         string psymbol = PositionGetString(POSITION_SYMBOL);
         long pmagic = PositionGetInteger(POSITION_MAGIC);
         if(psymbol == symbol && (ulong)pmagic == MagicNumber)
         {
            ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            found = true;
            break;
         }
      }

      if(found)
      {
         if(ptype == POSITION_TYPE_BUY)
            DeleteOrder(sellTicket);
         else if(ptype == POSITION_TYPE_SELL)
            DeleteOrder(buyTicket);
      }
   }
}

void ManageTrailingAndTimeExit(const string symbol, const double atrShort)
{
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;

      string psymbol = PositionGetString(POSITION_SYMBOL);
      long pmagic = PositionGetInteger(POSITION_MAGIC);
      if(psymbol != symbol || (ulong)pmagic != MagicNumber)
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double volume = PositionGetDouble(POSITION_VOLUME);
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);

      MqlTick tick;
      if(!SymbolInfoTick(symbol, tick))
         continue;

      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      int stopsLevelPts = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double minStopDist = stopsLevelPts * point;
      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

      double trailActivate = TRAIL_ACTIVATE_ATR * atrShort;
      double trailDistance = TRAIL_DISTANCE_ATR * atrShort;

      bool needModify = false;
      double newSL = currentSL;

      if(type == POSITION_TYPE_BUY)
      {
         double profitMove = tick.bid - openPrice;
         if(profitMove >= trailActivate)
         {
            double candidateSL = tick.bid - trailDistance;
            if((tick.bid - candidateSL) < minStopDist)
               candidateSL = tick.bid - minStopDist;

            if((currentSL <= 0.0 || candidateSL > currentSL + point) && candidateSL < tick.bid)
            {
               newSL = NormalizeDouble(candidateSL, digits);
               needModify = true;
            }
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profitMove = openPrice - tick.ask;
         if(profitMove >= trailActivate)
         {
            double candidateSL = tick.ask + trailDistance;
            if((candidateSL - tick.ask) < minStopDist)
               candidateSL = tick.ask + minStopDist;

            if((currentSL <= 0.0 || candidateSL < currentSL - point) && candidateSL > tick.ask)
            {
               newSL = NormalizeDouble(candidateSL, digits);
               needModify = true;
            }
         }
      }

      if(needModify)
         ModifyPositionSLTP(ticket, symbol, newSL, currentTP);

      int barsElapsed = iBarShift(symbol, PERIOD_M5, openTime, false);
      if(barsElapsed >= MaxTradeBars && MaxTradeBars > 0)
      {
         ClosePositionByTicket(ticket, symbol, type, volume);
      }
   }
}

void TryPlaceBreakoutOrders(const string symbol, const double atrShort)
{
   if(HasOpenPosition(symbol))
      return;

   bool hasBuyStop, hasSellStop;
   ulong buyTicket, sellTicket;
   GetPendingStops(symbol, hasBuyStop, buyTicket, hasSellStop, sellTicket);

   if(hasBuyStop && hasSellStop)
      return;

   if(!IsTradeEnvironmentSafe(symbol, atrShort))
      return;

   double buyStop = 0.0, sellStop = 0.0;
   if(!GetBreakoutLevels(symbol, buyStop, sellStop))
      return;

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int stopsLevelPts = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDist = stopsLevelPts * point;

   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick))
      return;

   double slDistance = SL_ATR_MULTIPLIER * atrShort;
   double tpDistance = TP_ATR_MULTIPLIER * atrShort;

   if(slDistance <= 0.0 || tpDistance <= 0.0)
      return;

   double volume = CalculateRiskVolume(symbol, slDistance);
   if(volume <= 0.0)
      return;

   if(!hasBuyStop)
   {
      double entry = MathMax(buyStop, tick.ask + minStopDist);
      double sl = entry - slDistance;
      double tp = entry + tpDistance;
      if(sl < entry && tp > entry)
         PlaceStopOrder(symbol, ORDER_TYPE_BUY_STOP, volume, NormalizeDouble(entry, digits), sl, tp);
   }

   if(!hasSellStop)
   {
      double entry = MathMin(sellStop, tick.bid - minStopDist);
      double sl = entry + slDistance;
      double tp = entry - tpDistance;
      if(sl > entry && tp < entry)
         PlaceStopOrder(symbol, ORDER_TYPE_SELL_STOP, volume, NormalizeDouble(entry, digits), sl, tp);
   }
}

void ProcessSymbol(SymbolContext &ctx)
{
   if(!EnsureSymbolReady(ctx.symbol))
      return;

   MqlRates latest[];
   ArraySetAsSeries(latest, true);
   if(CopyRates(ctx.symbol, PERIOD_M5, 0, 2, latest) < 2)
      return;

   if(latest[0].time == ctx.lastProcessedBarTime)
   {
      double atrNow = 0.0;
      if(GetATR(ctx.atrShortHandle, atrNow))
      {
         ManagePendingPair(ctx.symbol);
         ManageTrailingAndTimeExit(ctx.symbol, atrNow);
      }
      return;
   }

   ctx.lastProcessedBarTime = latest[0].time;

   double atrShort = 0.0;
   double atrLong = 0.0;

   if(!GetATR(ctx.atrShortHandle, atrShort))
      return;
   if(!GetATR(ctx.atrLongHandle, atrLong))
      return;

   ManagePendingPair(ctx.symbol);
   ManageTrailingAndTimeExit(ctx.symbol, atrShort);

   if(atrShort < MinimumATR)
      return;

   if(atrShort < (ATR_COMPRESSION_FACTOR * atrLong))
   {
      TryPlaceBreakoutOrders(ctx.symbol, atrShort);
   }
}

int OnInit()
{
   string symbols[];
   int count = ParseSymbols(SymbolsList, symbols);
   if(count <= 0)
      return INIT_PARAMETERS_INCORRECT;

   ArrayResize(g_symbols, count);

   for(int i = 0; i < count; i++)
   {
      g_symbols[i].symbol = symbols[i];
      g_symbols[i].lastProcessedBarTime = 0;

      if(!EnsureSymbolReady(symbols[i]))
      {
         PrintFormat("Symbol not ready: %s", symbols[i]);
      }

      g_symbols[i].atrShortHandle = iATR(symbols[i], PERIOD_M5, ATR_SHORT_PERIOD);
      g_symbols[i].atrLongHandle = iATR(symbols[i], PERIOD_M5, ATR_LONG_PERIOD);

      if(g_symbols[i].atrShortHandle == INVALID_HANDLE || g_symbols[i].atrLongHandle == INVALID_HANDLE)
      {
         PrintFormat("Failed to create ATR handles for %s", symbols[i]);
      }
   }

   int timerSec = (TimerSeconds < 1 ? 1 : TimerSeconds);
   EventSetTimer(timerSec);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int)
{
   EventKillTimer();

   for(int i = 0; i < ArraySize(g_symbols); i++)
   {
      if(g_symbols[i].atrShortHandle != INVALID_HANDLE)
      {
         IndicatorRelease(g_symbols[i].atrShortHandle);
         g_symbols[i].atrShortHandle = INVALID_HANDLE;
      }

      if(g_symbols[i].atrLongHandle != INVALID_HANDLE)
      {
         IndicatorRelease(g_symbols[i].atrLongHandle);
         g_symbols[i].atrLongHandle = INVALID_HANDLE;
      }
   }
}

void OnTick()
{
   // Intentionally unused. All logic runs in OnTimer for multi-symbol operation.
}

void OnTimer()
{
   for(int i = 0; i < ArraySize(g_symbols); i++)
   {
      ProcessSymbol(g_symbols[i]);
   }
}
