#property strict
#property version   "1.02"
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
input int      StopLossBasePoints  = 600;
input int      StopLossStepPoints  = 150;

int      g_emaFastHandle = INVALID_HANDLE;
int      g_emaSlowHandle = INVALID_HANDLE;
double   g_initialEquity = 0.0;
bool     g_tradingStopped = false;
ulong    g_lastActionTickTime = 0;
bool     g_waitingLevelConfirmation = false;
int      g_expectedLevelsAfterSend = 0;

struct BasketState
{
   int                levels;
   ENUM_POSITION_TYPE firstType;
   ENUM_POSITION_TYPE lastType;
   ENUM_POSITION_TYPE expectedNextType;
   double             lastPrice;
   ulong              lastTicket;
   double             totalProfit;
};

struct BasketPosition
{
   ulong              ticket;
   long               timeMsc;
   ENUM_POSITION_TYPE type;
   double             price;
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


ENUM_POSITION_TYPE OppositePositionType(ENUM_POSITION_TYPE type)
{
   if(type == POSITION_TYPE_BUY)
      return POSITION_TYPE_SELL;
   return POSITION_TYPE_BUY;
}

ENUM_POSITION_TYPE ExpectedTypeForLevel(const BasketState &state, int levelNumber)
{
   if(levelNumber <= 1)
      return state.firstType;

   if((levelNumber % 2) == 1)
      return state.firstType;

   return OppositePositionType(state.firstType);
}

bool IsAlternatingBasket(const BasketState &state)
{
   if(state.levels <= 1)
      return true;

   ENUM_POSITION_TYPE expectedLast = ExpectedTypeForLevel(state, state.levels);
   return (expectedLast == state.lastType);
}


double ProgressiveStopDistancePoints(int levelNumber)
{
   if(levelNumber < 1)
      levelNumber = 1;

   int distancePoints = StopLossBasePoints + (levelNumber - 1) * StopLossStepPoints;

   int minStops = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(distancePoints < minStops)
      distancePoints = minStops;

   if(distancePoints < 0)
      distancePoints = 0;

   return (double)distancePoints;
}

double CalculateProgressiveSL(ENUM_ORDER_TYPE type, double entryPrice, int levelNumber)
{
   if(StopLossBasePoints <= 0)
      return 0.0;

   double distance = ProgressiveStopDistancePoints(levelNumber) * _Point;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(type == ORDER_TYPE_BUY)
      return NormalizeDouble(entryPrice - distance, digits);

   return NormalizeDouble(entryPrice + distance, digits);
}

double NormalizeVolume(double volume)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep <= 0.0)
      return 0.0;

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

bool SendMarketOrder(ENUM_ORDER_TYPE type, double volume, double slPrice, string comment)
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
      request.sl           = slPrice;
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

void SortBasketPositionsByOpenTime(BasketPosition &arr[])
{
   int n = ArraySize(arr);
   if(n < 2)
      return;

   for(int i = 0; i < n - 1; i++)
   {
      for(int j = i + 1; j < n; j++)
      {
         bool swapNeeded = false;

         if(arr[j].timeMsc < arr[i].timeMsc)
            swapNeeded = true;
         else if(arr[j].timeMsc == arr[i].timeMsc && arr[j].ticket < arr[i].ticket)
            swapNeeded = true;

         if(swapNeeded)
         {
            BasketPosition tmp = arr[i];
            arr[i] = arr[j];
            arr[j] = tmp;
         }
      }
   }
}

bool GetBasketState(BasketState &state)
{
   state.levels            = 0;
   state.firstType         = POSITION_TYPE_BUY;
   state.lastType          = POSITION_TYPE_BUY;
   state.expectedNextType  = POSITION_TYPE_SELL;
   state.lastPrice         = 0.0;
   state.lastTicket        = 0;
   state.totalProfit       = 0.0;

   BasketPosition positions[];
   ArrayResize(positions, 0);

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

      double profit = PositionGetDouble(POSITION_PROFIT)
                    + PositionGetDouble(POSITION_SWAP)
                    + PositionGetDouble(POSITION_COMMISSION);
      state.totalProfit += profit;

      int idx = ArraySize(positions);
      ArrayResize(positions, idx + 1);
      positions[idx].ticket  = ticket;
      positions[idx].timeMsc = PositionGetInteger(POSITION_TIME_MSC);
      positions[idx].type    = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      positions[idx].price   = PositionGetDouble(POSITION_PRICE_OPEN);
   }

   state.levels = ArraySize(positions);
   if(state.levels <= 0)
      return false;

   SortBasketPositionsByOpenTime(positions);

   state.firstType = positions[0].type;
   state.lastType  = positions[state.levels - 1].type;
   state.lastPrice = positions[state.levels - 1].price;
   state.lastTicket = positions[state.levels - 1].ticket;

   state.expectedNextType = ExpectedTypeForLevel(state, state.levels + 1);

   return true;
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

void UpdateSendConfirmationState(int currentLevels)
{
   if(!g_waitingLevelConfirmation)
      return;

   if(currentLevels >= g_expectedLevelsAfterSend)
   {
      g_waitingLevelConfirmation = false;
      g_expectedLevelsAfterSend = 0;
   }
}

bool CanOpenTradeNow()
{
   ulong nowMsc = (ulong)GetTickCount64();

   if(g_lastActionTickTime == nowMsc)
      return false;

   g_lastActionTickTime = nowMsc;
   return true;
}

void TryOpenInitialPosition()
{
   if(NewsFilter)
      return;
   if(!IsWithinTradingHours())
      return;
   if(CurrentSpreadPoints() > MaxSpread)
      return;
   if(!CanOpenTradeNow())
      return;

   int signal = GetTrendSignal();
   if(signal == 0)
      return;

   double lot = NormalizeVolume(LotStart);
   if(lot <= 0.0)
      return;

   ENUM_ORDER_TYPE type = (signal > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double entryPrice = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slPrice = CalculateProgressiveSL(type, entryPrice, 1);
   if(SendMarketOrder(type, lot, slPrice, "Level1"))
   {
      g_waitingLevelConfirmation = true;
      g_expectedLevelsAfterSend = 1;
   }
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
   if(!CanOpenTradeNow())
      return;

   if(!IsAlternatingBasket(state))
   {
      Print("Basket structure mismatch detected. Grid expansion skipped this tick.");
      return;
   }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double trigger = GridDistancePoints * _Point;

   bool shouldOpen = false;

   if(state.lastType == POSITION_TYPE_BUY)
   {
      if(bid <= state.lastPrice - trigger)
         shouldOpen = true;
   }
   else if(state.lastType == POSITION_TYPE_SELL)
   {
      if(ask >= state.lastPrice + trigger)
         shouldOpen = true;
   }

   if(!shouldOpen)
      return;

   double lot = NextLotSize(state.levels);
   if(lot <= 0.0)
      return;

   int nextLevel = state.levels + 1;
   ENUM_ORDER_TYPE nextType = (state.expectedNextType == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double entryPrice = (nextType == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slPrice = CalculateProgressiveSL(nextType, entryPrice, nextLevel);
   string comment = "Level" + IntegerToString(nextLevel);
   if(SendMarketOrder(nextType, lot, slPrice, comment))
   {
      g_waitingLevelConfirmation = true;
      g_expectedLevelsAfterSend = state.levels + 1;
   }
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

   UpdateSendConfirmationState(hasBasket ? state.levels : 0);

   if(g_waitingLevelConfirmation)
      return;

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
