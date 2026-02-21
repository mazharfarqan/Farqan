#property copyright ""
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//==============================
// Inputs (optimisables)
//==============================
input string InpBaseSymbol                 = "BTCUSD";   // Symbole de base (auto-suffix)
input ENUM_TIMEFRAMES InpTradeTF           = PERIOD_M5;  // Timeframe trading
input ENUM_TIMEFRAMES InpVolatilityTF      = PERIOD_M15; // Timeframe filtre volatilité
input double InpStartLot                   = 0.01;       // Lot initial
input double InpMultiplier                 = 1.7;        // Multiplicateur martingale
input int    InpMaxLevels                  = 6;          // Niveaux max (strict)
input int    InpATRPeriodTrade             = 14;         // ATR période M5
input int    InpATRPeriodVolFast           = 14;         // ATR période rapide M15
input int    InpATRPeriodVolSlow           = 50;         // ATR période lente M15
input double InpGridAtrFactor              = 0.7;        // Step grille = facteur * ATR(M5)
input double InpMaxTotalLot                = 2.00;       // Sécurité lot total absolu
input double InpBasketTPPercentBalance     = 0.35;       // TP global (% balance)
input double InpProfitLockStartPercent     = 0.20;       // Activation verrou profit (% balance)
input double InpProfitTrailRetracePercent  = 0.08;       // Retracement toléré (% balance)
input double InpEquityDDStopPercent        = 10.0;       // Equity stop (% drawdown)
input double InpLevel6LossStopPercent      = 5.0;        // Stop perte si niveau max atteint (% balance)
input int    InpPauseAfterWinMinutes       = 15;         // Pause après cycle gagnant (minutes)
input int    InpPauseAfterDDHours          = 12;         // Pause après drawdown stop (heures)
input long   InpMagicNumber                = 20260221;   // Magic Number
input int    InpMaxSpreadPoints            = 2000;       // Spread maximum (points)
input int    InpSlippagePoints             = 50;         // Déviation max (points)

//==============================
// Variables globales
//==============================
CTrade g_trade;
string g_symbol = "";
int    g_handleAtrTrade = INVALID_HANDLE;
int    g_handleAtrVolFast = INVALID_HANDLE;
int    g_handleAtrVolSlow = INVALID_HANDLE;

datetime g_pauseUntil = 0;
datetime g_lastBarTime = 0;
int      g_effectiveMaxLevels = 6;
int      g_effectiveMaxSpreadPoints = 2000;

double g_cycleBalanceAnchor = 0.0;
bool   g_profitLockActive = false;
double g_peakBasketProfit = 0.0;

//==============================
// Prototypes
//==============================
bool StartCycle();
bool OpenInitialHedge();
bool OpenNextGridLevel();
double CalculateNextLot(const int directionType);
double BasketProfit();
bool CloseBasket(const string reason);
bool EquityProtection();
bool VolatilityFilter();
bool PauseManager();

//==============================
// Outils internes
//==============================
string DetectSymbol(const string base)
{
   string best = "";
   int total = (int)SymbolsTotal(false);
   for(int i = 0; i < total; i++)
   {
      string s = SymbolName(i, false);
      if(StringLen(s) == 0)
         continue;

      string su = s;
      string bu = base;
      StringToUpper(su);
      StringToUpper(bu);

      if(StringFind(su, bu) == 0) // commence par BTCUSD
      {
         if(best == "" || StringLen(s) < StringLen(best))
            best = s;
      }
      else if(su == bu)
      {
         best = s;
         break;
      }
   }

   if(best == "")
      best = base;

   return best;
}

int CountPositions(const int type = -1)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      long magic = PositionGetInteger(POSITION_MAGIC);
      long ptype = PositionGetInteger(POSITION_TYPE);

      if(sym != g_symbol || magic != InpMagicNumber)
         continue;

      if(type == -1 || type == (int)ptype)
         count++;
   }
   return count;
}

double TotalLots()
{
   double lots = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      lots += PositionGetDouble(POSITION_VOLUME);
   }
   return lots;
}

double LastOpenPriceByType(const int type)
{
   datetime latest = 0;
   double price = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      if((int)PositionGetInteger(POSITION_TYPE) != type)
         continue;

      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(t >= latest)
      {
         latest = t;
         price = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }

   return price;
}

bool SpreadOK()
{
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick))
      return false;

   double spreadPoints = (tick.ask - tick.bid) / _Point;
   if(spreadPoints > g_effectiveMaxSpreadPoints)
   {
      PrintFormat("[SPREAD] Filtre actif. Spread=%.1f > max=%d points", spreadPoints, g_effectiveMaxSpreadPoints);
      return false;
   }
   return true;
}

bool IsNewBar(const ENUM_TIMEFRAMES tf)
{
   datetime t = iTime(g_symbol, tf, 0);
   if(t == 0)
      return false;

   if(g_lastBarTime != t)
   {
      g_lastBarTime = t;
      return true;
   }
   return false;
}

//==============================
// Cycle & Trading
//==============================
bool StartCycle()
{
   if(CountPositions() > 0)
      return false;

   if(!PauseManager())
      return false;

   if(!SpreadOK())
      return false;

   if(!VolatilityFilter())
      return false;

   if(!OpenInitialHedge())
      return false;

   g_cycleBalanceAnchor = AccountInfoDouble(ACCOUNT_BALANCE);
   g_profitLockActive = false;
   g_peakBasketProfit = 0.0;

   Print("[CYCLE] Nouveau cycle démarré.");
   return true;
}

bool OpenInitialHedge()
{
   if(!SpreadOK())
      return false;

   double minLot = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double lotStep = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);

   double lot = MathMax(InpStartLot, minLot);
   lot = MathFloor(lot / lotStep) * lotStep;
   lot = NormalizeDouble(lot, 2);

   if(lot <= 0.0)
   {
      Print("[ERROR] Lot initial invalide.");
      return false;
   }

   bool buyOk = g_trade.Buy(lot, g_symbol, 0.0, 0.0, 0.0, "Initial BUY");
   if(!buyOk)
      PrintFormat("[TRADE] Echec BUY initial. Retcode=%d", g_trade.ResultRetcode());

   bool sellOk = g_trade.Sell(lot, g_symbol, 0.0, 0.0, 0.0, "Initial SELL");
   if(!sellOk)
      PrintFormat("[TRADE] Echec SELL initial. Retcode=%d", g_trade.ResultRetcode());

   return (buyOk && sellOk);
}

double CalculateNextLot(const int directionType)
{
   int levels = CountPositions(directionType);
   if(levels <= 0)
      return InpStartLot;

   double rawLot = InpStartLot * MathPow(InpMultiplier, levels);

   double minLot = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);

   double lot = MathMax(rawLot, minLot);
   lot = MathMin(lot, maxLot);
   lot = MathFloor(lot / lotStep) * lotStep;
   lot = NormalizeDouble(lot, 2);

   return lot;
}

bool OpenNextGridLevel()
{
   if(!SpreadOK())
      return false;

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(g_handleAtrTrade, 0, 0, 2, atrBuf) < 2)
      return false;

   double gridStep = atrBuf[0] * InpGridAtrFactor;
   if(gridStep <= 0.0)
      return false;

   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick))
      return false;

   int buyLevels = CountPositions(POSITION_TYPE_BUY);
   int sellLevels = CountPositions(POSITION_TYPE_SELL);

   // Limite stricte à 6 niveaux par direction
   if(buyLevels < g_effectiveMaxLevels)
   {
      double lastBuyPrice = LastOpenPriceByType(POSITION_TYPE_BUY);
      if(lastBuyPrice > 0.0 && tick.bid <= (lastBuyPrice - gridStep))
      {
         double lot = CalculateNextLot(POSITION_TYPE_BUY);
         if(TotalLots() + lot <= InpMaxTotalLot)
         {
            if(g_trade.Buy(lot, g_symbol, 0.0, 0.0, 0.0, "Grid BUY"))
               PrintFormat("[GRID] BUY niveau %d ouvert. Lot=%.2f Step=%.2f", buyLevels + 1, lot, gridStep);
            else
               PrintFormat("[GRID] Echec BUY niveau %d. Retcode=%d", buyLevels + 1, g_trade.ResultRetcode());
         }
         else
            Print("[RISK] MaxTotalLot atteint. BUY ignoré.");
      }
   }

   if(sellLevels < g_effectiveMaxLevels)
   {
      double lastSellPrice = LastOpenPriceByType(POSITION_TYPE_SELL);
      if(lastSellPrice > 0.0 && tick.ask >= (lastSellPrice + gridStep))
      {
         double lot = CalculateNextLot(POSITION_TYPE_SELL);
         if(TotalLots() + lot <= InpMaxTotalLot)
         {
            if(g_trade.Sell(lot, g_symbol, 0.0, 0.0, 0.0, "Grid SELL"))
               PrintFormat("[GRID] SELL niveau %d ouvert. Lot=%.2f Step=%.2f", sellLevels + 1, lot, gridStep);
            else
               PrintFormat("[GRID] Echec SELL niveau %d. Retcode=%d", sellLevels + 1, g_trade.ResultRetcode());
         }
         else
            Print("[RISK] MaxTotalLot atteint. SELL ignoré.");
      }
   }

   return true;
}

double BasketProfit()
{
   double profit = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      profit += PositionGetDouble(POSITION_PROFIT);
      profit += PositionGetDouble(POSITION_SWAP);
      profit += PositionGetDouble(POSITION_COMMISSION);
   }

   return profit;
}

bool CloseBasket(const string reason)
{
   bool allClosed = true;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      if(!g_trade.PositionClose(ticket, InpSlippagePoints))
      {
         allClosed = false;
         PrintFormat("[CLOSE] Echec fermeture ticket %I64u. Retcode=%d", ticket, g_trade.ResultRetcode());
      }
   }

   if(allClosed)
      PrintFormat("[CLOSE] Panier clôturé. Raison: %s", reason);

   return allClosed;
}

bool EquityProtection()
{
   if(CountPositions() <= 0)
      return false;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   if(balance <= 0.0)
      return false;

   double ddPct = ((balance - equity) / balance) * 100.0;
   if(ddPct >= InpEquityDDStopPercent)
   {
      PrintFormat("[PROTECT] Equity stop déclenché. DD=%.2f%%", ddPct);
      CloseBasket("Equity Stop");
      g_pauseUntil = TimeCurrent() + (InpPauseAfterDDHours * 3600);
      g_profitLockActive = false;
      g_peakBasketProfit = 0.0;
      return true;
   }

   int buyLevels = CountPositions(POSITION_TYPE_BUY);
   int sellLevels = CountPositions(POSITION_TYPE_SELL);
   bool maxLevelReached = (buyLevels >= g_effectiveMaxLevels || sellLevels >= g_effectiveMaxLevels);

   double basket = BasketProfit();
   double lossLimit = -(balance * (InpLevel6LossStopPercent / 100.0));

   if(maxLevelReached && basket <= lossLimit)
   {
      PrintFormat("[PROTECT] Stop niveau max déclenché. Profit=%.2f <= %.2f", basket, lossLimit);
      CloseBasket("MaxLevel Loss Stop");
      g_profitLockActive = false;
      g_peakBasketProfit = 0.0;
      return true;
   }

   return false;
}

bool VolatilityFilter()
{
   double fast[];
   double slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);

   if(CopyBuffer(g_handleAtrVolFast, 0, 0, 2, fast) < 2)
      return false;
   if(CopyBuffer(g_handleAtrVolSlow, 0, 0, 2, slow) < 2)
      return false;

   bool ok = (fast[0] > slow[0]);
   if(!ok)
      PrintFormat("[FILTER] Volatilité insuffisante. ATR14=%.2f <= ATR50=%.2f", fast[0], slow[0]);
   return ok;
}

bool PauseManager()
{
   if(TimeCurrent() < g_pauseUntil)
   {
      int remain = (int)(g_pauseUntil - TimeCurrent());
      PrintFormat("[PAUSE] Trading en pause. Temps restant: %d sec", remain);
      return false;
   }

   return true;
}

//==============================
// Fonctions MT5
//==============================
int OnInit()
{
   g_symbol = DetectSymbol(InpBaseSymbol);
   if(!SymbolSelect(g_symbol, true))
   {
      PrintFormat("[INIT] Impossible de sélectionner symbole: %s", g_symbol);
      return INIT_FAILED;
   }

   g_effectiveMaxLevels = (int)MathMin((double)InpMaxLevels, 6.0);
   if(g_effectiveMaxLevels < 1)
      g_effectiveMaxLevels = 1;

   if(InpMaxLevels != g_effectiveMaxLevels)
      PrintFormat("[INIT] InpMaxLevels ajusté à %d (limite stricte).", g_effectiveMaxLevels);

   g_effectiveMaxSpreadPoints = InpMaxSpreadPoints;
   if(g_effectiveMaxSpreadPoints < 1800)
   {
      g_effectiveMaxSpreadPoints = 1800;
      PrintFormat("[INIT] InpMaxSpreadPoints ajusté à %d (minimum recommandé BTCUSD).", g_effectiveMaxSpreadPoints);
   }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippagePoints);

   g_handleAtrTrade = iATR(g_symbol, InpTradeTF, InpATRPeriodTrade);
   g_handleAtrVolFast = iATR(g_symbol, InpVolatilityTF, InpATRPeriodVolFast);
   g_handleAtrVolSlow = iATR(g_symbol, InpVolatilityTF, InpATRPeriodVolSlow);

   if(g_handleAtrTrade == INVALID_HANDLE || g_handleAtrVolFast == INVALID_HANDLE || g_handleAtrVolSlow == INVALID_HANDLE)
   {
      Print("[INIT] Erreur création indicateurs ATR.");
      return INIT_FAILED;
   }

   long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("[INIT] Attention: compte non-hedging détecté. Stratégie prévue pour hedging.");

   PrintFormat("[INIT] EA prêt. Symbole=%s Magic=%d", g_symbol, (int)InpMagicNumber);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_handleAtrTrade != INVALID_HANDLE)
      IndicatorRelease(g_handleAtrTrade);
   if(g_handleAtrVolFast != INVALID_HANDLE)
      IndicatorRelease(g_handleAtrVolFast);
   if(g_handleAtrVolSlow != INVALID_HANDLE)
      IndicatorRelease(g_handleAtrVolSlow);
}

void OnTick()
{
   // Protection prioritaire
   if(EquityProtection())
      return;

   int pos = CountPositions();

   // Démarrage cycle uniquement sur nouvelle bougie M5
   if(pos == 0 && IsNewBar(InpTradeTF))
   {
      StartCycle();
      return;
   }

   if(pos <= 0)
      return;

   // Extension grille
   OpenNextGridLevel();

   // Gestion profit panier
   double basket = BasketProfit();
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   double tpValue = balance * (InpBasketTPPercentBalance / 100.0);
   double lockStart = balance * (InpProfitLockStartPercent / 100.0);
   double trailDrop = balance * (InpProfitTrailRetracePercent / 100.0);

   if(basket >= tpValue)
   {
      if(CloseBasket("Global Basket TP"))
      {
         g_pauseUntil = TimeCurrent() + (InpPauseAfterWinMinutes * 60);
         g_profitLockActive = false;
         g_peakBasketProfit = 0.0;
      }
      return;
   }

   if(!g_profitLockActive && basket >= lockStart)
   {
      g_profitLockActive = true;
      g_peakBasketProfit = basket;
      PrintFormat("[LOCK] Verrou profit activé. Basket=%.2f", basket);
   }

   if(g_profitLockActive)
   {
      if(basket > g_peakBasketProfit)
         g_peakBasketProfit = basket;

      if(basket <= (g_peakBasketProfit - trailDrop))
      {
         if(CloseBasket("Trailing Equity Lock"))
         {
            g_pauseUntil = TimeCurrent() + (InpPauseAfterWinMinutes * 60);
            g_profitLockActive = false;
            g_peakBasketProfit = 0.0;
         }
      }
   }
}
