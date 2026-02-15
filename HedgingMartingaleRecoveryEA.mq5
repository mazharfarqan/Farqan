#property strict
#property version   "1.00"
#property description "Hedging Martingale Recovery EA for MT5"

input int      EMA_Fast            = 50;
input int      EMA_Slow            = 200;
input int      GridDistancePoints  = 300;
input double   LotStart            = 0.01;
input double   LotMultiplier       = 1.6;
input int      MaxLevels           = 10;
input double   TargetProfitUSD     = 5.0;
input int      MaxSpread           = 50;
input double   MaxDrawdownPercent  = 40.0;
input int      TradingStartHour    = 1;
input int      TradingEndHour      = 23;
input bool     NewsFilter          = false;
input long     MagicNumber         = 20260215;

int      g_emaFastHandle = INVALID_HANDLE;
int      g_emaSlowHandle = INVALID_HANDLE;
double   g_initialEquity = 0.0;
bool     g_tradingStopped = false;

struct BasketState
{
   int                levels;
   ENUM_POSITION_TYPE lastType;
   double             lastPrice;
   ulong              lastTicket;
   double             totalProfit;
};

bool IsHedgingAccount()
{
   long mode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   return (mode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}

bool IsWithinTradingHours()
{
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);

   if(TradingStartHour == TradingEndHour)
      return true;

   if(TradingStartHour < TradingEndHour)
      return (tm.hour >= TradingStartHour && tm.hour < TradingEndHour);

   return (tm.hour >= TradingStartHour || tm.hour < TradingEndHour);
}

int CurrentSpreadPoints()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return (int)MathRound((ask - bid) / _Point);
}

ENUM_ORDER_TYPE_FILLING GetFillingMode()
{
   int filling = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;

   return ORDER_FILLING_RETURN;
}

double NormalizeVolume(double volume)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double capped = MathMin(volume, 5.0);
   capped = MathMin(capped, maxLot);
   capped = MathMax(capped, minLot);

   double steps = MathFloor((capped - minLot) / lotStep + 0.5);
   double normalized = minLot + steps * lotStep;

   int volDigits = 2;
   if(lotStep > 0.0)
      volDigits = (int)MathRound(-MathLog10(lotStep));

   return NormalizeDouble(normalized, volDigits);
}

bool SendMarketOrder(ENUM_ORDER_TYPE type, double volume, string comment)
{
   MqlTradeRequest request;
   MqlTradeResult  result;

   ENUM_ORDER_TYPE_FILLING filling = GetFillingMode();

   int retries = 3;
   for(int attempt = 0; attempt < retries; attempt++)
   {
      ZeroMemory(request);
      ZeroMemory(result);

      double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                               : SymbolInfoDouble(_Symbol, SYMBOL_BID);

      request.action       = TRADE_ACTION_DEAL;
      request.symbol       = _Symbol;
      request.magic        = MagicNumber;
      request.volume       = volume;
      request.type         = type;
      request.price        = price;
      request.deviation    = 20;
      request.type_filling = filling;
      request.comment      = comment;

      if(OrderSend(request, result))
      {
         if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_DONE_PARTIAL)
            return true;

         if(result.retcode == TRADE_RETCODE_REQUOTE || result.retcode == TRADE_RETCODE_PRICE_CHANGED)
         {
            Sleep(200);
            continue;
         }
      }
      else
      {
         int err = GetLastError();
         if(err == ERR_REQUOTE || err == ERR_PRICE_CHANGED)
         {
            Sleep(200);
            continue;
         }
      }

      PrintFormat("OrderSend failed. Attempt=%d Retcode=%u", attempt + 1, result.retcode);
      Sleep(200);
   }

   return false;
}

bool ClosePositionByTicket(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return false;

   ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double volume            = PositionGetDouble(POSITION_VOLUME);

   ENUM_ORDER_TYPE closeType = (ptype == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   ENUM_ORDER_TYPE_FILLING filling = GetFillingMode();

   MqlTradeRequest request;
   MqlTradeResult  result;

   int retries = 3;
   for(int attempt = 0; attempt < retries; attempt++)
   {
      ZeroMemory(request);
      ZeroMemory(result);

      request.action       = TRADE_ACTION_DEAL;
      request.symbol       = _Symbol;
      request.position     = ticket;
      request.magic        = MagicNumber;
      request.type         = closeType;
      request.volume       = volume;
      request.price        = (closeType == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                                            : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      request.deviation    = 20;
      request.type_filling = filling;
      request.comment      = "BasketClose";

      if(OrderSend(request, result))
      {
         if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_DONE_PARTIAL)
            return true;

         if(result.retcode == TRADE_RETCODE_REQUOTE || result.retcode == TRADE_RETCODE_PRICE_CHANGED)
         {
            Sleep(200);
            continue;
         }
      }

      Sleep(200);
   }

   PrintFormat("Close failed for ticket %I64u", ticket);
   return false;
}

int CollectBasketTickets(ulong &tickets[])
{
   ArrayResize(tickets, 0);
   int total = PositionsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      long magic    = PositionGetInteger(POSITION_MAGIC);

      if(symbol == _Symbol && magic == MagicNumber)
      {
         int idx = ArraySize(tickets);
         ArrayResize(tickets, idx + 1);
         tickets[idx] = ticket;
      }
   }

   return ArraySize(tickets);
}

void CloseAllBasketPositions()
{
   ulong tickets[];
   int count = CollectBasketTickets(tickets);

   for(int i = count - 1; i >= 0; i--)
      ClosePositionByTicket(tickets[i]);
}

bool GetBasketState(BasketState &state)
{
   state.levels     = 0;
   state.lastType   = POSITION_TYPE_BUY;
   state.lastPrice  = 0.0;
   state.lastTicket = 0;
   state.totalProfit = 0.0;

   long latestTime = -1;
   int total = PositionsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      state.levels++;

      double profit = PositionGetDouble(POSITION_PROFIT)
                    + PositionGetDouble(POSITION_SWAP)
                    + PositionGetDouble(POSITION_COMMISSION);
      state.totalProfit += profit;

      long openTime = PositionGetInteger(POSITION_TIME_MSC);
      if(openTime > latestTime)
      {
         latestTime      = openTime;
         state.lastType  = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         state.lastPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         state.lastTicket = ticket;
      }
   }

   return (state.levels > 0);
}

int GetTrendSignal()
{
   double fastBuf[2], slowBuf[2];
   if(CopyBuffer(g_emaFastHandle, 0, 0, 2, fastBuf) < 2)
      return 0;
   if(CopyBuffer(g_emaSlowHandle, 0, 0, 2, slowBuf) < 2)
      return 0;

   if(fastBuf[0] > slowBuf[0])
      return 1;
   if(fastBuf[0] < slowBuf[0])
      return -1;

   return 0;
}

double NextLotSize(int currentLevels)
{
   double lot = LotStart * MathPow(LotMultiplier, currentLevels);
   return NormalizeVolume(lot);
}

void TryOpenInitialPosition()
{
   if(NewsFilter)
      return;
   if(!IsWithinTradingHours())
      return;
   if(CurrentSpreadPoints() > MaxSpread)
      return;

   int signal = GetTrendSignal();
   if(signal == 0)
      return;

   double lot = NormalizeVolume(LotStart);
   if(lot <= 0.0)
      return;

   ENUM_ORDER_TYPE type = (signal > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   SendMarketOrder(type, lot, "Level1");
}

void TryOpenNextGridLevel(const BasketState &state)
{
   if(state.levels <= 0)
      return;
   if(state.levels >= MaxLevels)
      return;
   if(NewsFilter)
      return;
   if(!IsWithinTradingHours())
      return;
   if(CurrentSpreadPoints() > MaxSpread)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double trigger = GridDistancePoints * _Point;

   bool shouldOpen = false;
   ENUM_ORDER_TYPE nextType = ORDER_TYPE_BUY;

   if(state.lastType == POSITION_TYPE_BUY)
   {
      if(bid <= state.lastPrice - trigger)
      {
         shouldOpen = true;
         nextType = ORDER_TYPE_SELL;
      }
   }
   else if(state.lastType == POSITION_TYPE_SELL)
   {
      if(ask >= state.lastPrice + trigger)
      {
         shouldOpen = true;
         nextType = ORDER_TYPE_BUY;
      }
   }

   if(!shouldOpen)
      return;

   double lot = NextLotSize(state.levels);
   if(lot <= 0.0)
      return;

   string comment = "Level" + IntegerToString(state.levels + 1);
   SendMarketOrder(nextType, lot, comment);
}

void CheckDrawdownProtection()
{
   if(g_tradingStopped)
      return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_initialEquity <= 0.0)
      g_initialEquity = AccountInfoDouble(ACCOUNT_BALANCE);

   double dd = 0.0;
   if(g_initialEquity > 0.0)
      dd = (g_initialEquity - equity) / g_initialEquity * 100.0;

   if(dd > MaxDrawdownPercent)
   {
      Print("Max drawdown exceeded. Closing all positions and stopping EA.");
      CloseAllBasketPositions();
      g_tradingStopped = true;
      ExpertRemove();
   }
}

int OnInit()
{
   if(!IsHedgingAccount())
   {
      Print("This EA requires a hedging account.");
      return INIT_FAILED;
   }

   g_initialEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   g_emaFastHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   g_emaSlowHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   if(g_emaFastHandle == INVALID_HANDLE || g_emaSlowHandle == INVALID_HANDLE)
   {
      Print("Failed to create EMA handles.");
      return INIT_FAILED;
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_emaFastHandle != INVALID_HANDLE)
      IndicatorRelease(g_emaFastHandle);
   if(g_emaSlowHandle != INVALID_HANDLE)
      IndicatorRelease(g_emaSlowHandle);
}

void OnTick()
{
   if(g_tradingStopped)
      return;

   CheckDrawdownProtection();
   if(g_tradingStopped)
      return;

   BasketState state;
   bool hasBasket = GetBasketState(state);

   if(hasBasket)
   {
      if(state.totalProfit >= TargetProfitUSD)
      {
         CloseAllBasketPositions();
         return;
      }

      TryOpenNextGridLevel(state);
      return;
   }

   TryOpenInitialPosition();
}
