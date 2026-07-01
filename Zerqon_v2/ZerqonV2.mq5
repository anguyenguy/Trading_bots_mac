//+------------------------------------------------------------------+
//|                                              ZerqonClone.mq5      |
//|   Phase 1 clone of "Zerqon EA" behavior (XAUUSD M15)             |
//|   - Full money-management shell (max 5 pos, ATR SL, small TP,    |
//|     break-even, trailing, time/spread filter, risk sizing)      |
//|   - Signal core = indicator SURROGATE, isolated in ModelSignal() |
//|     so Phase 2 can swap it for an LSTM/ONNX model.              |
//+------------------------------------------------------------------+
#property copyright "clone research / educational"
#property version   "0.20"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//==================== INPUTS ==========================================
input group "=== General ==="
input long   InpMagic          = 20260701;
input int    InpMaxPositions    = 5;        // trần lệnh song song (bản gốc = 5)
input int    InpSlippage        = 30;       // điểm

input group "=== Money management ==="
input bool   InpUseRiskSizing   = false;    // false=lot cố định, true=theo risk
input double InpFixedLot         = 0.01;
input double InpRiskLevel        = 0.007;    // như 'Signal Risk Level' bản gốc
input double InpMaxLot           = 5.0;

input group "=== TP / SL (theo báo cáo phân tích) ==="
input double InpTakeProfitUSD    = 4.0;      // TP nhỏ, gần cố định (~$4 / 0.01 lot)
input bool   InpUseATRStop       = true;     // SL theo ATR (khớp hành vi bản gốc)
input int    InpATRPeriod        = 14;
input double InpATR_SL_Mult      = 1.5;      // SL = ATR * mult (siết thêm: giảm avg loss & DD)
input double InpFixedStopUSD     = 21.0;     // dùng khi InpUseATRStop=false

input group "=== Break-even & Trailing ==="
input bool   InpUseBreakeven     = true;
input double InpBE_TriggerUSD    = 3.2;      // chỉ dời hòa khi gần chạm TP -> không cắt lời non
input double InpBE_LockUSD       = 1.5;      // khóa lời khá -> nâng avg win
input bool   InpUseTrailing      = false;    // TẮT: để TP nhỏ là cửa thoát chính (giống bản gốc)
input double InpTrailStartUSD    = 6.0;      // nếu bật lại: chỉ trail khi đã vượt TP (ôm runner)
input double InpTrailDistUSD     = 3.0;      // nới rộng để không bóp lời

input group "=== Signal surrogate (Phase 1) ==="
input int    InpFastEMA          = 12;
input int    InpSlowEMA          = 48;
input int    InpADXPeriod        = 14;
input double InpADXmin           = 20.0;     // chỉ vào khi có xu hướng -> 'không giao dịch liên tục'
input int    InpBreakoutBars     = 6;        // xác nhận momentum breakout

input group "=== Filters (time / spread) ==="
input double InpMaxSpreadUSD     = 0.60;
input bool   InpUseTimeFilter    = true;
input int    InpStartHour        = 1;        // giờ server
input int    InpEndHour          = 22;
input bool   InpBlockFriLate     = true;     // tránh cuối phiên thứ 6

//==================== GLOBALS =========================================
int hFast, hSlow, hADX, hATR;
datetime lastBar = 0;
double  gPoint, gTickSize, gTickValue;

//======================================================================
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   hFast = iMA (_Symbol, PERIOD_M15, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA (_Symbol, PERIOD_M15, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hADX  = iADX(_Symbol, PERIOD_M15, InpADXPeriod);
   hATR  = iATR(_Symbol, PERIOD_M15, InpATRPeriod);
   if(hFast==INVALID_HANDLE||hSlow==INVALID_HANDLE||hADX==INVALID_HANDLE||hATR==INVALID_HANDLE)
      return INIT_FAILED;

   gPoint     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   gTickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   gTickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int r)
{
   IndicatorRelease(hFast); IndicatorRelease(hSlow);
   IndicatorRelease(hADX);  IndicatorRelease(hATR);
}

//======================================================================
void OnTick()
{
   ManageOpenPositions();                 // break-even + trailing mỗi tick

   datetime bt = iTime(_Symbol, PERIOD_M15, 0);
   if(bt == lastBar) return;              // chỉ đánh giá vào lệnh 1 lần/nến M15
   lastBar = bt;

   if(!PassFilters()) return;

   int dir = ModelSignal();               // <<< LÕI TÍN HIỆU (Phase 2 thay bằng ONNX)
   if(dir == 0) return;

   if(CountMyPositions() >= InpMaxPositions) return;

   OpenTrade(dir);
}

//======================================================================
//  ModelSignal(): trả +1 (mua) / -1 (bán) / 0 (đứng ngoài)
//  PHASE 1  = surrogate: EMA trend + ADX gate + breakout momentum.
//  PHASE 2  = thay toàn bộ thân hàm bằng suy luận ONNX (giữ nguyên interface).
//======================================================================
int ModelSignal()
{
   double f[2], s[2], adx[2], atr[1];
   if(CopyBuffer(hFast,0,1,2,f)  < 2) return 0;
   if(CopyBuffer(hSlow,0,1,2,s)  < 2) return 0;
   if(CopyBuffer(hADX ,0,1,2,adx)< 2) return 0;   // buffer 0 = ADX chính
   if(CopyBuffer(hATR ,0,1,1,atr)< 1) return 0;

   if(adx[1] < InpADXmin) return 0;               // thị trường sideway -> không vào

   // hướng xu hướng
   int trend = 0;
   if(f[1] > s[1]) trend = 1;
   else if(f[1] < s[1]) trend = -1;
   if(trend == 0) return 0;

   // xác nhận momentum breakout theo hướng xu hướng
   double hh = iHigh(_Symbol, PERIOD_M15, iHighest(_Symbol,PERIOD_M15,MODE_HIGH,InpBreakoutBars,2));
   double ll = iLow (_Symbol, PERIOD_M15, iLowest (_Symbol,PERIOD_M15,MODE_LOW ,InpBreakoutBars,2));
   double c1 = iClose(_Symbol, PERIOD_M15, 1);

   if(trend > 0 && c1 > hh) return  1;
   if(trend < 0 && c1 < ll) return -1;
   return 0;
}

//======================================================================
bool PassFilters()
{
   double spread = SymbolInfoDouble(_Symbol,SYMBOL_ASK) - SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(spread > InpMaxSpreadUSD) return false;

   if(InpUseTimeFilter)
   {
      MqlDateTime t; TimeToStruct(TimeCurrent(), t);
      if(t.hour < InpStartHour || t.hour >= InpEndHour) return false;
      if(InpBlockFriLate && t.day_of_week==5 && t.hour>=20) return false;
   }
   // TODO Phase 1.5: news filter qua Economic Calendar (CalendarValueHistory)
   return true;
}

//======================================================================
void OpenTrade(int dir)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double atr[1];
   if(CopyBuffer(hATR,0,1,1,atr) < 1) return;

   double slDist = InpUseATRStop ? (atr[0]*InpATR_SL_Mult) : InpFixedStopUSD;
   double tpDist = InpTakeProfitUSD;
   double lot    = CalcLot(slDist);
   if(lot <= 0) return;

   double price, sl, tp;
   if(dir > 0){
      price = ask;
      sl = price - slDist;
      tp = price + tpDist;
      trade.Buy(lot, _Symbol, price, sl, tp, "ZerqonClone");
   } else {
      price = bid;
      sl = price + slDist;
      tp = price - tpDist;
      trade.Sell(lot, _Symbol, price, sl, tp, "ZerqonClone");
   }
}

//======================================================================
double CalcLot(double slDist)
{
   double lot = InpFixedLot;
   if(InpUseRiskSizing && slDist > 0 && gTickSize > 0 && gTickValue > 0)
   {
      double riskMoney  = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskLevel;
      double lossPerLot = (slDist / gTickSize) * gTickValue;   // lỗ khi SL với 1.0 lot
      if(lossPerLot > 0) lot = riskMoney / lossPerLot;
   }
   // chuẩn hóa theo broker
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot/step)*step;
   lot = MathMax(minL, MathMin(lot, MathMin(maxL, InpMaxLot)));
   return lot;
}

//======================================================================
int CountMyPositions()
{
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong tk = PositionGetTicket(i);
      if(PositionSelectByTicket(tk)
         && PositionGetInteger(POSITION_MAGIC)==InpMagic
         && PositionGetString(POSITION_SYMBOL)==_Symbol) n++;
   }
   return n;
}

//======================================================================
void ManageOpenPositions()
{
   if(!InpUseBreakeven && !InpUseTrailing) return;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;

      long   type  = PositionGetInteger(POSITION_TYPE);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double newSL = curSL;

      if(type==POSITION_TYPE_BUY)
      {
         double profit = bid - open;                    // $ cho 0.01 lot ~ = chênh giá
         if(InpUseBreakeven && profit>=InpBE_TriggerUSD)
            newSL = MathMax(newSL, open + InpBE_LockUSD);
         if(InpUseTrailing  && profit>=InpTrailStartUSD)
            newSL = MathMax(newSL, bid - InpTrailDistUSD);
         if(newSL > curSL + gPoint)
            trade.PositionModify(tk, NormalizeDouble(newSL,_Digits), tp);
      }
      else if(type==POSITION_TYPE_SELL)
      {
         double profit = open - ask;
         if(InpUseBreakeven && profit>=InpBE_TriggerUSD)
            newSL = (curSL==0)? open-InpBE_LockUSD : MathMin(newSL, open - InpBE_LockUSD);
         if(InpUseTrailing  && profit>=InpTrailStartUSD)
            newSL = (newSL==0)? ask+InpTrailDistUSD : MathMin(newSL, ask + InpTrailDistUSD);
         if(newSL < curSL - gPoint || curSL==0)
            trade.PositionModify(tk, NormalizeDouble(newSL,_Digits), tp);
      }
   }
}
//+------------------------------------------------------------------+
