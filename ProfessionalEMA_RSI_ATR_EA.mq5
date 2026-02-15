#property strict
#property version   "2.00"
#property description "Professional M1 scalping EA with institutional-grade execution safety"

#include <Trade/Trade.mqh>

input long   magic_number         = 90527197;
input double risk_percent         = 1.0;
input double atr_multiplier       = 1.4;
input double rr_ratio             = 1.2;
input int    max_spread           = 18;
input double max_daily_loss       = 4.0;
input int    max_trades_per_day   = 8;
input int    session_start        = 7;
input int    session_end          = 21;
input double min_atr              = 0.00035;

input int    slippage_points      = 10;
input int    max_retries          = 5;
input int    retry_delay_ms       = 120;

input int    ema_fast_period      = 20;
input int    ema_trend_period     = 50;
input int    rsi_period           = 7;
input int    adx_period           = 14;
input int    atr_period           = 14;
input double adx_minimum          = 20.0;

CTrade trade;

int      hEMA20 = INVALID_HANDLE;
int      hEMA50 = INVALID_HANDLE;
int      hRSI   = INVALID_HANDLE;
int      hADX   = INVALID_HANDLE;
int      hATR   = INVALID_HANDLE;

datetime last_bar_time = 0;
int      day_of_year   = -1;
double   day_start_balance = 0.0;
int      trades_today = 0;

void Log(const string msg)
{
   Print("[SCALPER] ", msg);
}

string GvPartialKey(const ulong ticket)
{
   return StringFormat("SCALPER_PARTIAL_%I64u_%s", ticket, _Symbol);
}

void ResetDailyCountersIfNeeded()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   if(day_of_year != now.day_of_year)
   {
      day_of_year = now.day_of_year;
      day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      trades_today = 0;
      Log(StringFormat("New day reset. day=%d start_balance=%.2f", day_of_year, day_start_balance));
   }
}

bool IsNewBar()
{
   datetime t0 = iTime(_Symbol, PERIOD_M1, 0);
   if(t0 <= 0)
      return false;

   if(last_bar_time == 0)
   {
      last_bar_time = t0;
      return false;
   }

   if(t0 != last_bar_time)
   {
      last_bar_time = t0;
      return true;
   }
   return false;
}

bool IsWithinSession()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);

   if(session_start == session_end)
      return true;

   if(session_start < session_end)
      return (now.hour >= session_start && now.hour < session_end);

   return (now.hour >= session_start || now.hour < session_end);
}

bool IsDailyLossHit()
{
   if(day_start_balance <= 0.0)
      return false;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double loss_pct = 100.0 * (day_start_balance - equity) / day_start_balance;
   if(loss_pct >= max_daily_loss)
   {
      Log(StringFormat("Trading blocked: daily loss %.2f%% >= %.2f%%", loss_pct, max_daily_loss));
      return true;
   }
   return false;
}

bool IsSpreadValid(MqlTick &tick, double &spread_points)
{
   if(!SymbolInfoTick(_Symbol, tick))
   {
      Log("Trading blocked: SymbolInfoTick failed.");
      return false;
   }

   spread_points = (tick.ask - tick.bid) / _Point;
   if(spread_points > max_spread)
   {
      Log(StringFormat("Trading blocked: spread %.1f > max %d", spread_points, max_spread));
      return false;
   }
   return true;
}

bool HasAnyOpenPositionOnSymbol()
{
   return PositionSelect(_Symbol);
}

bool CheckStopsAndFreezeDistance(const ENUM_ORDER_TYPE type, const double price, const double sl, const double tp)
{
   int stop_level_pts   = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freeze_level_pts = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);

   double min_stop   = stop_level_pts * _Point;
   double min_freeze = freeze_level_pts * _Point;

   double dsl = MathAbs(price - sl);
   double dtp = MathAbs(tp - price);

   if(dsl < min_stop || dtp < min_stop)
   {
      Log(StringFormat("Trading blocked: invalid stops. dSL=%.5f dTP=%.5f minStop=%.5f", dsl, dtp, min_stop));
      return false;
   }

   if(dsl <= min_freeze || dtp <= min_freeze)
   {
      Log(StringFormat("Trading blocked: freeze level violation. dSL=%.5f dTP=%.5f freeze=%.5f", dsl, dtp, min_freeze));
      return false;
   }

   if(type == ORDER_TYPE_BUY && !(sl < price && tp > price))
      return false;
   if(type == ORDER_TYPE_SELL && !(sl > price && tp < price))
      return false;

   return true;
}

double NormalizeVolume(double vol)
{
   double vmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(vstep <= 0.0)
      return 0.0;

   vol = MathFloor(vol / vstep) * vstep;
   if(vol < vmin)
      vol = vmin;
   if(vol > vmax)
      vol = vmax;

   int vol_digits = 0;
   if(vstep < 1.0)
   {
      double x = vstep;
      while(x < 1.0 && vol_digits < 8)
      {
         x *= 10.0;
         vol_digits++;
      }
   }

   return NormalizeDouble(vol, vol_digits);
}

double CalculateRiskLot(const double stop_points)
{
   if(stop_points <= 0.0)
      return 0.0;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_amount = balance * (risk_percent / 100.0);

   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tick_value <= 0.0 || tick_size <= 0.0)
   {
      Log("Risk calc blocked: invalid tick_value/tick_size.");
      return 0.0;
   }

   double value_per_point_per_lot = tick_value * (_Point / tick_size);
   if(value_per_point_per_lot <= 0.0)
      return 0.0;

   double raw_lot = risk_amount / (stop_points * value_per_point_per_lot);
   double lot = NormalizeVolume(raw_lot);

   Log(StringFormat("Risk calc: balance=%.2f risk=%.2f stop_points=%.1f raw=%.4f lot=%.2f",
                    balance, risk_amount, stop_points, raw_lot, lot));

   return lot;
}

bool CheckMargin(const ENUM_ORDER_TYPE type, const double volume, const double price)
{
   double margin = 0.0;
   if(!OrderCalcMargin(type, _Symbol, volume, price, margin))
   {
      Log(StringFormat("Trading blocked: OrderCalcMargin failed err=%d", GetLastError()));
      return false;
   }

   double free_margin = AccountInfoDouble(ACCOUNT_FREEMARGIN);
   if(free_margin < margin)
   {
      Log(StringFormat("Trading blocked: insufficient margin free=%.2f required=%.2f", free_margin, margin));
      return false;
   }
   return true;
}

bool LoadIndicators(double &ema20_1, double &ema50_1,
                    double &rsi_1, double &rsi_2,
                    double &adx_1, double &atr_1,
                    double &open_1, double &close_1,
                    double &low_1, double &high_1,
                    double &close_2)
{
   double bEMA20[1], bEMA50[1], bRSI[2], bADX[1], bATR[1], bOpen1[1], bClose1[1], bLow1[1], bHigh1[1], bClose2[1];

   if(CopyBuffer(hEMA20, 0, 1, 1, bEMA20) != 1) return false;
   if(CopyBuffer(hEMA50, 0, 1, 1, bEMA50) != 1) return false;
   if(CopyBuffer(hRSI,   0, 1, 2, bRSI)   != 2) return false;
   if(CopyBuffer(hADX,   0, 1, 1, bADX)   != 1) return false;
   if(CopyBuffer(hATR,   0, 1, 1, bATR)   != 1) return false;

   if(CopyOpen(_Symbol, PERIOD_M1, 1, 1, bOpen1)  != 1) return false;
   if(CopyClose(_Symbol, PERIOD_M1, 1, 1, bClose1)!= 1) return false;
   if(CopyLow(_Symbol, PERIOD_M1, 1, 1, bLow1)    != 1) return false;
   if(CopyHigh(_Symbol, PERIOD_M1, 1, 1, bHigh1)  != 1) return false;
   if(CopyClose(_Symbol, PERIOD_M1, 2, 1, bClose2)!= 1) return false;

   ema20_1 = bEMA20[0];
   ema50_1 = bEMA50[0];
   rsi_1   = bRSI[0];
   rsi_2   = bRSI[1];
   adx_1   = bADX[0];
   atr_1   = bATR[0];

   open_1  = bOpen1[0];
   close_1 = bClose1[0];
   low_1   = bLow1[0];
   high_1  = bHigh1[0];
   close_2 = bClose2[0];

   return true;
}

bool CalcSessionVWAP(double &vwap)
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   now.hour = 0;
   now.min = 0;
   now.sec = 0;
   datetime day_start = StructToTime(now);

   int bars = Bars(_Symbol, PERIOD_M1, day_start, TimeCurrent());
   if(bars <= 2)
      return false;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, PERIOD_M1, 1, bars - 1, rates);
   if(copied <= 0)
      return false;

   double pv_sum = 0.0;
   double vol_sum = 0.0;

   for(int i = copied - 1; i >= 0; i--)
   {
      double tp = (rates[i].high + rates[i].low + rates[i].close) / 3.0;
      double vol = (double)rates[i].tick_volume;
      if(vol <= 0.0)
         vol = 1.0;
      pv_sum += tp * vol;
      vol_sum += vol;
   }

   if(vol_sum <= 0.0)
      return false;

   vwap = pv_sum / vol_sum;
   return true;
}

bool RetryableRetcode(const long rc)
{
   return (rc == TRADE_RETCODE_REQUOTE ||
           rc == TRADE_RETCODE_PRICE_CHANGED ||
           rc == TRADE_RETCODE_INVALID_PRICE ||
           rc == TRADE_RETCODE_TRADE_CONTEXT_BUSY ||
           rc == TRADE_RETCODE_TOO_MANY_REQUESTS ||
           rc == TRADE_RETCODE_CONNECTION ||
           rc == TRADE_RETCODE_TIMEOUT);
}

bool ExecuteOrder(const ENUM_ORDER_TYPE type, const double volume, const double sl, const double tp)
{
   for(int i = 0; i < max_retries; i++)
   {
      trade.SetExpertMagicNumber(magic_number);
      trade.SetDeviationInPoints(slippage_points);
      ResetLastError();

      bool ok = false;
      if(type == ORDER_TYPE_BUY)
         ok = trade.Buy(volume, _Symbol, 0.0, sl, tp, "SCALP_BUY");
      else
         ok = trade.Sell(volume, _Symbol, 0.0, sl, tp, "SCALP_SELL");

      long rc = trade.ResultRetcode();
      string rd = trade.ResultRetcodeDescription();

      if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
      {
         Log(StringFormat("Order executed [%d/%d] ret=%d %s", i + 1, max_retries, rc, rd));
         return true;
      }

      Log(StringFormat("Order failed [%d/%d] ret=%d %s err=%d", i + 1, max_retries, rc, rd, GetLastError()));
      if(!RetryableRetcode(rc))
         return false;

      Sleep(retry_delay_ms);
   }

   return false;
}

bool ModifyPositionSLTP(const double new_sl, const double tp)
{
   int freeze_level_pts = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double freeze_dist = freeze_level_pts * _Point;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double ref_price = (ptype == POSITION_TYPE_BUY) ? tick.bid : tick.ask;

   if(MathAbs(ref_price - new_sl) <= freeze_dist)
   {
      Log("SL modify blocked: freeze level too close.");
      return false;
   }

   trade.SetExpertMagicNumber(magic_number);

   for(int i = 0; i < max_retries; i++)
   {
      bool ok = trade.PositionModify(_Symbol, NormalizeDouble(new_sl, _Digits), NormalizeDouble(tp, _Digits));
      long rc = trade.ResultRetcode();
      if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
         return true;

      if(!RetryableRetcode(rc))
         return false;

      Sleep(retry_delay_ms);
   }

   return false;
}

void ManageOpenPosition()
{
   if(!PositionSelect(_Symbol))
      return;

   long pmagic = PositionGetInteger(POSITION_MAGIC);
   if(pmagic != magic_number)
      return;

   ulong  ticket     = (ulong)PositionGetInteger(POSITION_TICKET);
   double volume     = PositionGetDouble(POSITION_VOLUME);
   double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl         = PositionGetDouble(POSITION_SL);
   double tp         = PositionGetDouble(POSITION_TP);
   ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   double atrb[1];
   if(CopyBuffer(hATR, 0, 1, 1, atrb) != 1)
      return;

   double atr = atrb[0];
   if(atr <= 0.0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double risk_dist = MathMax(atr * atr_multiplier, (double)((int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + 1) * _Point);
   double price_now = (ptype == POSITION_TYPE_BUY) ? tick.bid : tick.ask;
   double profit_dist = (ptype == POSITION_TYPE_BUY) ? (price_now - open_price) : (open_price - price_now);

   double be_trigger = 0.8 * risk_dist;
   if(profit_dist >= be_trigger)
   {
      double be_sl = open_price;
      bool move_be = false;
      if(ptype == POSITION_TYPE_BUY && (sl < be_sl || sl == 0.0)) move_be = true;
      if(ptype == POSITION_TYPE_SELL && (sl > be_sl || sl == 0.0)) move_be = true;

      if(move_be && ModifyPositionSLTP(be_sl, tp))
      {
         Log(StringFormat("Exit mgmt: Break-even moved at +0.8R, new SL=%.5f", be_sl));
         sl = be_sl;
      }
   }

   string partial_key = GvPartialKey(ticket);
   bool partial_done = GlobalVariableCheck(partial_key);
   if(!partial_done && profit_dist >= risk_dist)
   {
      double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double minv  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double close_vol = NormalizeVolume(volume * 0.5);

      if(close_vol >= minv && (volume - close_vol) >= minv && vstep > 0.0)
      {
         trade.SetExpertMagicNumber(magic_number);
         trade.SetDeviationInPoints(slippage_points);
         bool closed = trade.PositionClosePartial(_Symbol, close_vol);
         long rc = trade.ResultRetcode();
         if(closed && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
         {
            GlobalVariableSet(partial_key, (double)TimeCurrent());
            Log(StringFormat("Exit mgmt: Partial close 50%% done at 1R, closed=%.2f", close_vol));
         }
      }
   }

   if(profit_dist >= be_trigger)
   {
      double trail_sl = (ptype == POSITION_TYPE_BUY) ? (price_now - risk_dist) : (price_now + risk_dist);
      bool improve = false;

      if(ptype == POSITION_TYPE_BUY && trail_sl > sl) improve = true;
      if(ptype == POSITION_TYPE_SELL && (sl == 0.0 || trail_sl < sl)) improve = true;

      if(improve && ModifyPositionSLTP(trail_sl, tp))
         Log(StringFormat("Exit mgmt: ATR trailing SL updated to %.5f", trail_sl));
   }
}

void EvaluateEntries()
{
   ResetDailyCountersIfNeeded();

   if(IsDailyLossHit())
      return;

   if(trades_today >= max_trades_per_day)
   {
      Log(StringFormat("Trading blocked: max trades/day reached (%d)", trades_today));
      return;
   }

   if(!IsWithinSession())
   {
      Log("Trading blocked: outside London/NY session window.");
      return;
   }

   if(HasAnyOpenPositionOnSymbol())
   {
      Log("Trading blocked: one position per symbol rule.");
      return;
   }

   MqlTick tick;
   double spread_pts = 0.0;
   if(!IsSpreadValid(tick, spread_pts))
      return;

   double ema20_1 = 0.0, ema50_1 = 0.0, rsi_1 = 0.0, rsi_2 = 0.0, adx_1 = 0.0, atr_1 = 0.0;
   double open_1 = 0.0, close_1 = 0.0, low_1 = 0.0, high_1 = 0.0, close_2 = 0.0;

   if(!LoadIndicators(ema20_1, ema50_1, rsi_1, rsi_2, adx_1, atr_1, open_1, close_1, low_1, high_1, close_2))
   {
      Log("Trading blocked: indicator load failed.");
      return;
   }

   if(atr_1 < min_atr)
   {
      Log(StringFormat("Trading blocked: ATR %.5f < min %.5f", atr_1, min_atr));
      return;
   }

   if(adx_1 < adx_minimum)
   {
      Log(StringFormat("Trading blocked: ADX %.2f < %.2f", adx_1, adx_minimum));
      return;
   }

   double vwap = 0.0;
   if(!CalcSessionVWAP(vwap))
   {
      Log("Trading blocked: VWAP calculation failed.");
      return;
   }

   bool trend_up   = (close_1 > ema50_1 && close_1 > vwap && close_1 > close_2);
   bool trend_down = (close_1 < ema50_1 && close_1 < vwap && close_1 < close_2);

   bool pullback_buy  = (low_1 <= ema20_1 && close_1 > ema20_1);
   bool pullback_sell = (high_1 >= ema20_1 && close_1 < ema20_1);

   bool rsi_cross_up   = (rsi_2 <= 50.0 && rsi_1 > 50.0);
   bool rsi_cross_down = (rsi_2 >= 50.0 && rsi_1 < 50.0);

   bool prev_bull = (close_1 > open_1);
   bool prev_bear = (close_1 < open_1);

   bool buy_signal  = trend_up && pullback_buy && rsi_cross_up && prev_bull;
   bool sell_signal = trend_down && pullback_sell && rsi_cross_down && prev_bear;

   if(!buy_signal && !sell_signal)
   {
      Log(StringFormat("No entry: trendUp=%d trendDn=%d pullBuy=%d pullSell=%d rsiUp=%d rsiDn=%d bull=%d bear=%d",
                       (int)trend_up, (int)trend_down, (int)pullback_buy, (int)pullback_sell,
                       (int)rsi_cross_up, (int)rsi_cross_down, (int)prev_bull, (int)prev_bear));
      return;
   }

   ENUM_ORDER_TYPE type = buy_signal ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double entry = buy_signal ? tick.ask : tick.bid;
   entry = NormalizeDouble(entry, _Digits);

   double stop_dist = MathMax(atr_1 * atr_multiplier,
                              (double)((int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + 1) * _Point);

   double sl = 0.0;
   double tp = 0.0;

   if(type == ORDER_TYPE_BUY)
   {
      sl = NormalizeDouble(entry - stop_dist, _Digits);
      tp = NormalizeDouble(entry + (stop_dist * rr_ratio), _Digits);
   }
   else
   {
      sl = NormalizeDouble(entry + stop_dist, _Digits);
      tp = NormalizeDouble(entry - (stop_dist * rr_ratio), _Digits);
   }

   if(!CheckStopsAndFreezeDistance(type, entry, sl, tp))
      return;

   double stop_points = stop_dist / _Point;
   double lot = CalculateRiskLot(stop_points);
   if(lot <= 0.0)
   {
      Log("Trading blocked: computed lot <= 0.");
      return;
   }

   if(!CheckMargin(type, lot, entry))
      return;

   Log(StringFormat("Entry reason: %s trend+VWAP+ADX valid, pullback to EMA20, RSI cross 50, spread=%.1f, ATR=%.5f",
                    (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), spread_pts, atr_1));

   if(ExecuteOrder(type, lot, sl, tp))
   {
      trades_today++;
      Log(StringFormat("Entry executed: %s lot=%.2f entry=%.5f sl=%.5f tp=%.5f trades_today=%d",
                       (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), lot, entry, sl, tp, trades_today));
   }
   else
   {
      Log("Entry failed: execution retries exhausted or non-retryable retcode.");
   }
}

int OnInit()
{
   if(_Period != PERIOD_M1)
      Log("Warning: EA optimized for M1 timeframe.");

   trade.SetExpertMagicNumber(magic_number);
   trade.SetDeviationInPoints(slippage_points);

   hEMA20 = iMA(_Symbol, PERIOD_M1, ema_fast_period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA50 = iMA(_Symbol, PERIOD_M1, ema_trend_period, 0, MODE_EMA, PRICE_CLOSE);
   hRSI   = iRSI(_Symbol, PERIOD_M1, rsi_period, PRICE_CLOSE);
   hADX   = iADX(_Symbol, PERIOD_M1, adx_period);
   hATR   = iATR(_Symbol, PERIOD_M1, atr_period);

   if(hEMA20 == INVALID_HANDLE || hEMA50 == INVALID_HANDLE || hRSI == INVALID_HANDLE || hADX == INVALID_HANDLE || hATR == INVALID_HANDLE)
   {
      Log("Initialization failed: indicator handle creation error.");
      return INIT_FAILED;
   }

   ResetDailyCountersIfNeeded();
   Log("Initialization complete.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hEMA20 != INVALID_HANDLE) IndicatorRelease(hEMA20);
   if(hEMA50 != INVALID_HANDLE) IndicatorRelease(hEMA50);
   if(hRSI   != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hADX   != INVALID_HANDLE) IndicatorRelease(hADX);
   if(hATR   != INVALID_HANDLE) IndicatorRelease(hATR);

   Log(StringFormat("Deinitialized. reason=%d", reason));
}

void OnTick()
{
   ResetDailyCountersIfNeeded();
   ManageOpenPosition();

   if(IsNewBar())
      EvaluateEntries();
}
