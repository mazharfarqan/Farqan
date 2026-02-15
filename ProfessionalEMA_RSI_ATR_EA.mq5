#property strict
#property version   "1.00"
#property description "Professional EMA/RSI/ATR Expert Advisor with risk management and execution safety"

#include <Trade/Trade.mqh>

input long   magic_number               = 90527131;
input double risk_percent               = 1.0;
input double rr_ratio                   = 2.0;
input double atr_multiplier             = 1.5;
input int    max_spread_points          = 30;
input double max_daily_drawdown_percent = 5.0;
input int    trading_start_hour         = 0;
input int    trading_end_hour           = 23;
input int    ema_fast                   = 50;
input int    ema_slow                   = 200;
input int    rsi_period                 = 14;
input int    atr_period                 = 14;
input int    max_slippage_points        = 20;
input int    retry_count                = 3;
input int    retry_delay_ms             = 300;

CTrade trade;

int      hEMAfast = INVALID_HANDLE;
int      hEMAslow = INVALID_HANDLE;
int      hRSI     = INVALID_HANDLE;
int      hATR     = INVALID_HANDLE;
datetime last_bar_time = 0;

double   day_start_balance = 0.0;
int      day_of_year       = -1;

void Log(const string msg)
{
   Print("[EA] ", msg);
}

bool IsNewBar()
{
   datetime bar_time = iTime(_Symbol, _Period, 0);
   if(bar_time <= 0)
      return false;

   if(last_bar_time == 0)
   {
      last_bar_time = bar_time;
      return false;
   }

   if(bar_time != last_bar_time)
   {
      last_bar_time = bar_time;
      return true;
   }
   return false;
}

void UpdateDailyBaseline()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   if(day_of_year != now.day_of_year)
   {
      day_of_year = now.day_of_year;
      day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      Log(StringFormat("New day baseline set. Day=%d Balance=%.2f", day_of_year, day_start_balance));
   }
}

bool IsDailyDrawdownExceeded()
{
   if(day_start_balance <= 0.0)
      return false;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd_pct = 100.0 * (day_start_balance - equity) / day_start_balance;
   if(dd_pct >= max_daily_drawdown_percent)
   {
      Log(StringFormat("Daily drawdown limit reached: %.2f%% >= %.2f%%", dd_pct, max_daily_drawdown_percent));
      return true;
   }
   return false;
}

bool IsWithinTradingHours()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);

   if(trading_start_hour == trading_end_hour)
      return true;

   if(trading_start_hour < trading_end_hour)
      return (now.hour >= trading_start_hour && now.hour < trading_end_hour);

   return (now.hour >= trading_start_hour || now.hour < trading_end_hour);
}

bool IsSpreadOk()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
   {
      Log("Failed to get symbol tick for spread check.");
      return false;
   }

   double spread_points = (tick.ask - tick.bid) / _Point;
   if(spread_points > max_spread_points)
   {
      Log(StringFormat("Spread too high: %.1f points > %d", spread_points, max_spread_points));
      return false;
   }
   return true;
}

bool HasOpenPositionOnSymbol()
{
   if(!PositionSelect(_Symbol))
      return false;

   long mg = PositionGetInteger(POSITION_MAGIC);
   if(mg == magic_number)
      return true;

   Log("Existing position detected on symbol (different magic). New trade blocked by one-trade-per-symbol rule.");
   return true;
}

bool IsTradingAllowedForDirection(const ENUM_ORDER_TYPE type)
{
   long trade_mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(trade_mode == SYMBOL_TRADE_MODE_DISABLED)
   {
      Log("Trading disabled for symbol.");
      return false;
   }

   if(type == ORDER_TYPE_BUY && trade_mode == SYMBOL_TRADE_MODE_SHORTONLY)
   {
      Log("Buy not allowed: symbol is short-only.");
      return false;
   }

   if(type == ORDER_TYPE_SELL && trade_mode == SYMBOL_TRADE_MODE_LONGONLY)
   {
      Log("Sell not allowed: symbol is long-only.");
      return false;
   }

   return true;
}

double NormalizeVolume(const double vol)
{
   double min_vol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_vol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step_vol <= 0.0)
      return 0.0;

   double normalized = MathFloor(vol / step_vol) * step_vol;
   normalized = MathMax(min_vol, normalized);
   normalized = MathMin(max_vol, normalized);
   return normalized;
}

double CalculateLotByRisk(const double sl_distance_points)
{
   if(sl_distance_points <= 0.0)
      return 0.0;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_amount = balance * (risk_percent / 100.0);

   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tick_value <= 0.0 || tick_size <= 0.0)
   {
      Log("Invalid tick value/tick size, cannot calculate lot.");
      return 0.0;
   }

   double value_per_point_per_lot = tick_value * (_Point / tick_size);
   if(value_per_point_per_lot <= 0.0)
      return 0.0;

   double raw_lot = risk_amount / (sl_distance_points * value_per_point_per_lot);
   double lot = NormalizeVolume(raw_lot);

   Log(StringFormat("Lot calc: balance=%.2f risk=%.2f sl_points=%.1f raw=%.4f lot=%.2f",
                    balance, risk_amount, sl_distance_points, raw_lot, lot));

   return lot;
}

bool CheckFreeMargin(const ENUM_ORDER_TYPE type, const double volume, const double price)
{
   double margin = 0.0;
   if(!OrderCalcMargin(type, _Symbol, volume, price, margin))
   {
      Log(StringFormat("OrderCalcMargin failed. err=%d", GetLastError()));
      return false;
   }

   double free_margin = AccountInfoDouble(ACCOUNT_FREEMARGIN);
   if(free_margin < margin)
   {
      Log(StringFormat("Insufficient free margin. Required=%.2f Free=%.2f", margin, free_margin));
      return false;
   }

   return true;
}

bool BuildStops(const ENUM_ORDER_TYPE type, const double entry_price, const double atr_value, double &sl, double &tp, double &risk_distance)
{
   if(atr_value <= 0.0)
      return false;

   double raw_risk = atr_value * atr_multiplier;

   int stop_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_stop_distance = stop_level * _Point;

   risk_distance = MathMax(raw_risk, min_stop_distance + _Point);

   if(type == ORDER_TYPE_BUY)
   {
      sl = entry_price - risk_distance;
      tp = entry_price + risk_distance * rr_ratio;
   }
   else
   {
      sl = entry_price + risk_distance;
      tp = entry_price - risk_distance * rr_ratio;
   }

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   return true;
}

bool SendOrderWithRetry(const ENUM_ORDER_TYPE type, const double volume, const double sl, const double tp)
{
   bool result = false;

   for(int i = 0; i < retry_count; i++)
   {
      ResetLastError();
      trade.SetExpertMagicNumber(magic_number);
      trade.SetDeviationInPoints(max_slippage_points);

      if(type == ORDER_TYPE_BUY)
         result = trade.Buy(volume, _Symbol, 0.0, sl, tp, "EMA/RSI Buy");
      else
         result = trade.Sell(volume, _Symbol, 0.0, sl, tp, "EMA/RSI Sell");

      long retcode = trade.ResultRetcode();
      string retmsg = trade.ResultRetcodeDescription();

      if(result && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED))
      {
         Log(StringFormat("Order success [%d/%d]. Retcode=%d (%s)", i + 1, retry_count, retcode, retmsg));
         return true;
      }

      Log(StringFormat("Order attempt failed [%d/%d]. Retcode=%d (%s) LastError=%d",
                       i + 1, retry_count, retcode, retmsg, GetLastError()));

      bool retryable = (retcode == TRADE_RETCODE_REQUOTE ||
                        retcode == TRADE_RETCODE_PRICE_CHANGED ||
                        retcode == TRADE_RETCODE_REJECT ||
                        retcode == TRADE_RETCODE_TIMEOUT ||
                        retcode == TRADE_RETCODE_CONNECTION);

      if(!retryable)
         break;

      Sleep(retry_delay_ms);
   }

   return false;
}

void ManagePositionTrailingAndBreakeven()
{
   if(!PositionSelect(_Symbol))
      return;

   long mg = PositionGetInteger(POSITION_MAGIC);
   if(mg != magic_number)
      return;

   ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl         = PositionGetDouble(POSITION_SL);
   double tp         = PositionGetDouble(POSITION_TP);

   double atr_buf[];
   if(CopyBuffer(hATR, 0, 1, 1, atr_buf) <= 0)
      return;

   double atr_value = atr_buf[0];
   if(atr_value <= 0.0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double risk_distance = atr_value * atr_multiplier;
   int stop_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_stop_distance = stop_level * _Point;
   risk_distance = MathMax(risk_distance, min_stop_distance + _Point);

   double current_price = (pos_type == POSITION_TYPE_BUY) ? tick.bid : tick.ask;
   double move_in_profit = (pos_type == POSITION_TYPE_BUY) ? (current_price - open_price) : (open_price - current_price);

   bool need_modify = false;
   double new_sl = sl;

   if(move_in_profit >= risk_distance)
   {
      double be_sl = open_price;
      if(pos_type == POSITION_TYPE_BUY)
      {
         if(sl < be_sl)
         {
            new_sl = be_sl;
            need_modify = true;
         }
      }
      else
      {
         if(sl == 0.0 || sl > be_sl)
         {
            new_sl = be_sl;
            need_modify = true;
         }
      }
   }

   double trail_sl;
   if(pos_type == POSITION_TYPE_BUY)
   {
      trail_sl = tick.bid - risk_distance;
      if((new_sl == 0.0 || trail_sl > new_sl) && (tick.bid - trail_sl) >= min_stop_distance)
      {
         new_sl = trail_sl;
         need_modify = true;
      }
   }
   else
   {
      trail_sl = tick.ask + risk_distance;
      if((new_sl == 0.0 || trail_sl < new_sl) && (trail_sl - tick.ask) >= min_stop_distance)
      {
         new_sl = trail_sl;
         need_modify = true;
      }
   }

   if(need_modify)
   {
      new_sl = NormalizeDouble(new_sl, _Digits);
      trade.SetExpertMagicNumber(magic_number);
      if(trade.PositionModify(_Symbol, new_sl, tp))
      {
         Log(StringFormat("Position modified. New SL=%.5f TP=%.5f", new_sl, tp));
      }
      else
      {
         Log(StringFormat("Position modify failed. Retcode=%d (%s)", trade.ResultRetcode(), trade.ResultRetcodeDescription()));
      }
   }
}

bool GetIndicators(double &ema_fast_prev, double &ema_fast_curr,
                   double &ema_slow_prev, double &ema_slow_curr,
                   double &rsi_curr, double &atr_curr,
                   double &close_prev)
{
   double fast_buf[2], slow_buf[2], rsi_buf[1], atr_buf[1], close_buf[1];

   if(CopyBuffer(hEMAfast, 0, 1, 2, fast_buf) != 2)
      return false;
   if(CopyBuffer(hEMAslow, 0, 1, 2, slow_buf) != 2)
      return false;
   if(CopyBuffer(hRSI, 0, 1, 1, rsi_buf) != 1)
      return false;
   if(CopyBuffer(hATR, 0, 1, 1, atr_buf) != 1)
      return false;
   if(CopyClose(_Symbol, _Period, 1, 1, close_buf) != 1)
      return false;

   ema_fast_curr = fast_buf[0];
   ema_fast_prev = fast_buf[1];
   ema_slow_curr = slow_buf[0];
   ema_slow_prev = slow_buf[1];
   rsi_curr      = rsi_buf[0];
   atr_curr      = atr_buf[0];
   close_prev    = close_buf[0];

   return true;
}

void EvaluateEntryOnNewBar()
{
   if(!IsWithinTradingHours())
   {
      Log("Outside trading session.");
      return;
   }

   if(IsDailyDrawdownExceeded())
      return;

   if(!IsSpreadOk())
      return;

   if(HasOpenPositionOnSymbol())
      return;

   double ema_fast_prev, ema_fast_curr, ema_slow_prev, ema_slow_curr, rsi_curr, atr_curr, close_prev;
   if(!GetIndicators(ema_fast_prev, ema_fast_curr, ema_slow_prev, ema_slow_curr, rsi_curr, atr_curr, close_prev))
   {
      Log("Failed to read indicators.");
      return;
   }

   bool cross_up   = (ema_fast_prev <= ema_slow_prev && ema_fast_curr > ema_slow_curr);
   bool cross_down = (ema_fast_prev >= ema_slow_prev && ema_fast_curr < ema_slow_curr);

   bool buy_signal  = cross_up && (close_prev > ema_slow_curr) && (rsi_curr > 55.0);
   bool sell_signal = cross_down && (close_prev < ema_slow_curr) && (rsi_curr < 45.0);

   if(!buy_signal && !sell_signal)
   {
      Log(StringFormat("No signal. EMAfast_prev=%.5f EMAfast=%.5f EMAslow_prev=%.5f EMAslow=%.5f RSI=%.2f",
                       ema_fast_prev, ema_fast_curr, ema_slow_prev, ema_slow_curr, rsi_curr));
      return;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   ENUM_ORDER_TYPE order_type = buy_signal ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!IsTradingAllowedForDirection(order_type))
      return;

   double entry_price = buy_signal ? tick.ask : tick.bid;
   double sl = 0.0, tp = 0.0, risk_distance = 0.0;

   if(!BuildStops(order_type, entry_price, atr_curr, sl, tp, risk_distance))
   {
      Log("Failed to build stops.");
      return;
   }

   double sl_points = risk_distance / _Point;
   double volume = CalculateLotByRisk(sl_points);

   if(volume <= 0.0)
   {
      Log("Calculated volume is invalid.");
      return;
   }

   if(!CheckFreeMargin(order_type, volume, entry_price))
      return;

   Log(StringFormat("Signal=%s Entry=%.5f SL=%.5f TP=%.5f ATR=%.5f Volume=%.2f",
                    buy_signal ? "BUY" : "SELL", entry_price, sl, tp, atr_curr, volume));

   if(!SendOrderWithRetry(order_type, volume, sl, tp))
      Log("Order execution failed after retries.");
}

int OnInit()
{
   trade.SetExpertMagicNumber(magic_number);
   trade.SetDeviationInPoints(max_slippage_points);

   hEMAfast = iMA(_Symbol, _Period, ema_fast, 0, MODE_EMA, PRICE_CLOSE);
   hEMAslow = iMA(_Symbol, _Period, ema_slow, 0, MODE_EMA, PRICE_CLOSE);
   hRSI     = iRSI(_Symbol, _Period, rsi_period, PRICE_CLOSE);
   hATR     = iATR(_Symbol, _Period, atr_period);

   if(hEMAfast == INVALID_HANDLE || hEMAslow == INVALID_HANDLE || hRSI == INVALID_HANDLE || hATR == INVALID_HANDLE)
   {
      Log("Indicator handle creation failed.");
      return INIT_FAILED;
   }

   UpdateDailyBaseline();
   Log("EA initialized successfully.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hEMAfast != INVALID_HANDLE)
      IndicatorRelease(hEMAfast);
   if(hEMAslow != INVALID_HANDLE)
      IndicatorRelease(hEMAslow);
   if(hRSI != INVALID_HANDLE)
      IndicatorRelease(hRSI);
   if(hATR != INVALID_HANDLE)
      IndicatorRelease(hATR);

   Log(StringFormat("EA deinitialized. Reason=%d", reason));
}

void OnTick()
{
   UpdateDailyBaseline();
   ManagePositionTrailingAndBreakeven();

   if(IsNewBar())
      EvaluateEntryOnNewBar();
}
