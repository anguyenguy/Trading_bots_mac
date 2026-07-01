//+------------------------------------------------------------------+
//|                                         ZerqonClone_ONNX.mq5      |
//|   Phase 2: lõi tín hiệu = LSTM (ONNX) tự train. Khung MM giữ    |
//|   nguyên từ Phase 1 (max 5 lệnh, TP nhỏ, SL ATR, BE, trailing).|
//|                                                                  |
//|   CÀI ĐẶT:                                                       |
//|   1) Đặt file  zerqon_lstm.onnx  CÙNG THƯ MỤC với .mq5 này.     |
//|   2) Đặt file  ZerqonScaler.mqh  (do emit_mql5.py sinh) cùng chỗ.|
//|   3) Biên dịch. ONNX được nhúng thẳng vào .ex5 (self-contained). |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
#include "ZerqonScaler.mqh"          // ZQ_SEQ_LEN, ZQ_NFEAT, ZQ_MEAN[], ZQ_STD[]
#resource "zerqon_lstm.onnx" as uchar ExtModelBuf[]

CTrade trade;
#define ZQ_NCLASS 2                  // NoGo, Go  (hướng lấy từ trend EMA)

//==================== INPUTS (MM giống Phase 1) =======================
input group "=== Model ==="
input double InpConfThreshold  = 0.52;   // tối ưu theo backtest: PF 1.08, recovery 2.07
input group "=== General ==="
input long   InpMagic          = 20260702;
input int    InpMaxPositions    = 5;
input int    InpSlippage        = 30;
input group "=== Money management ==="
input bool   InpUseRiskSizing   = false;
input double InpFixedLot         = 0.01;
input double InpRiskLevel        = 0.007;
input double InpMaxLot           = 5.0;
input group "=== TP / SL (PHẢI khớp rào nhãn: TP=1.0*ATR, SL=2.5*ATR) ==="
input int    InpATRPeriod        = 14;
input bool   InpUseATRTP         = true;   // TP theo ATR (khớp nhãn); false = TP cố định USD
input double InpATR_TP_Mult      = 1.0;
input double InpTakeProfitUSD    = 4.0;    // chỉ dùng khi InpUseATRTP=false
input bool   InpUseATRStop       = true;
input double InpATR_SL_Mult      = 2.5;    // khớp SL_ATR_MULT khi train
input double InpFixedStopUSD     = 21.0;
input group "=== Break-even & Trailing (tắt để test thuần model trước) ==="
input bool   InpUseBreakeven     = false;
input double InpBE_TriggerUSD    = 3.2;
input double InpBE_LockUSD       = 1.5;
input bool   InpUseTrailing      = false;
input double InpTrailStartUSD    = 6.0;
input double InpTrailDistUSD     = 3.0;
input group "=== Filters ==="
input double InpMaxSpreadUSD     = 0.60;
input bool   InpUseTimeFilter    = true;
input int    InpStartHour        = 1;
input int    InpEndHour          = 22;
input bool   InpBlockFriLate     = true;
input group "=== Bảo vệ tài khoản (demo/live) ==="
input bool   InpUseEquityStop    = true;
input double InpEquityStopPct     = 30.0;  // dừng HẲN + đóng lệnh nếu equity giảm quá % so với lúc chạy
input bool   InpUseDailyLoss      = true;
input double InpMaxDailyLossPct   = 10.0;  // nghỉ hết ngày nếu lỗ trong ngày vượt %

//==================== GLOBALS =========================================
long   gModel = INVALID_HANDLE;
int    hEMAf, hEMAs, hEMA200, hRSI, hATRfeat, hATRstop;
datetime lastBar = 0;
double gPoint, gTickSize, gTickValue;
double gStartEquity = 0, gDayStartEquity = 0;
int    gDayOfYear = -1; bool gHalted = false;

// PHẢI khớp config.py
#define ZQ_EMA_FAST 20
#define ZQ_EMA_SLOW 50
#define ZQ_EMA_HTF  200
#define ZQ_RSI_PER  14
#define ZQ_ATR_FEAT 14
#define ZQ_RANGE_N  20

//======================================================================
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   // ---- nạp ONNX từ resource ----
   gModel = OnnxCreateFromBuffer(ExtModelBuf, ONNX_DEFAULT);
   if(gModel == INVALID_HANDLE){ Print("OnnxCreateFromBuffer lỗi: ", GetLastError()); return INIT_FAILED; }
   const long in_shape[]  = {1, ZQ_SEQ_LEN, ZQ_NFEAT};
   const long out_shape[] = {1, ZQ_NCLASS};
   if(!OnnxSetInputShape (gModel, 0, in_shape))  { Print("SetInputShape lỗi ", GetLastError());  return INIT_FAILED; }
   if(!OnnxSetOutputShape(gModel, 0, out_shape)) { Print("SetOutputShape lỗi ", GetLastError()); return INIT_FAILED; }

   // ---- indicator cho feature (khớp Python: EMA=alpha 2/(n+1), RSI/ATR = Wilder) ----
   hEMAf    = iMA (_Symbol, PERIOD_M15, ZQ_EMA_FAST, 0, MODE_EMA, PRICE_CLOSE);
   hEMAs    = iMA (_Symbol, PERIOD_M15, ZQ_EMA_SLOW, 0, MODE_EMA, PRICE_CLOSE);
   hEMA200  = iMA (_Symbol, PERIOD_M15, ZQ_EMA_HTF,  0, MODE_EMA, PRICE_CLOSE);
   hRSI     = iRSI(_Symbol, PERIOD_M15, ZQ_RSI_PER, PRICE_CLOSE);
   hATRfeat = iATR(_Symbol, PERIOD_M15, ZQ_ATR_FEAT);
   hATRstop = iATR(_Symbol, PERIOD_M15, InpATRPeriod);
   if(hEMAf==INVALID_HANDLE||hEMAs==INVALID_HANDLE||hEMA200==INVALID_HANDLE||hRSI==INVALID_HANDLE||
      hATRfeat==INVALID_HANDLE||hATRstop==INVALID_HANDLE) return INIT_FAILED;

   gPoint     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   gTickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   gTickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   gStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int r)
{
   if(gModel != INVALID_HANDLE) OnnxRelease(gModel);
   IndicatorRelease(hEMAf); IndicatorRelease(hEMAs); IndicatorRelease(hEMA200);
   IndicatorRelease(hRSI); IndicatorRelease(hATRfeat); IndicatorRelease(hATRstop);
}

//======================================================================
void OnTick()
{
   ManageOpenPositions();
   if(!RiskGuardOk()) return;         // circuit-breaker: chặn mở lệnh mới nếu vi phạm

   datetime bt = iTime(_Symbol, PERIOD_M15, 0);
   if(bt == lastBar) return;
   lastBar = bt;

   if(!PassFilters()) return;
   int dir = ModelSignal();          // <<< LÕI ONNX
   if(dir == 0) return;
   if(CountMyPositions() >= InpMaxPositions) return;
   OpenTrade(dir);
}

//======================================================================
//  ModelSignal(): build feature window -> chuẩn hóa -> ONNX -> argmax
//======================================================================
int ModelSignal()
{
   int need = ZQ_SEQ_LEN + ZQ_RANGE_N + 6;   // dư cho cửa sổ RANGE_N và ret4
   double c[], o[], h[], l[], ef[], es[], e2[], rs[], at[];
   datetime tm[];
   ArraySetAsSeries(c,true);  ArraySetAsSeries(o,true);  ArraySetAsSeries(h,true);
   ArraySetAsSeries(l,true);  ArraySetAsSeries(ef,true); ArraySetAsSeries(es,true);
   ArraySetAsSeries(e2,true); ArraySetAsSeries(rs,true); ArraySetAsSeries(at,true);
   ArraySetAsSeries(tm,true);

   if(CopyClose(_Symbol,PERIOD_M15,0,need,c)  < need) return 0;
   if(CopyOpen (_Symbol,PERIOD_M15,0,need,o)  < need) return 0;
   if(CopyHigh (_Symbol,PERIOD_M15,0,need,h)  < need) return 0;
   if(CopyLow  (_Symbol,PERIOD_M15,0,need,l)  < need) return 0;
   if(CopyTime (_Symbol,PERIOD_M15,0,need,tm) < need) return 0;
   if(CopyBuffer(hEMAf,0,0,need,ef) < need) return 0;
   if(CopyBuffer(hEMAs,0,0,need,es) < need) return 0;
   if(CopyBuffer(hEMA200,0,0,need,e2) < need) return 0;
   if(CopyBuffer(hRSI ,0,0,need,rs) < need) return 0;
   if(CopyBuffer(hATRfeat,0,0,need,at) < need) return 0;

   float inp[];
   ArrayResize(inp, ZQ_SEQ_LEN * ZQ_NFEAT);
   double eps = 1e-9;

   // bar shift j: 1=nến đóng gần nhất ... ZQ_SEQ_LEN=cũ nhất
   // seqpos = ZQ_SEQ_LEN - j  (0=cũ nhất, khớp cửa sổ Python)
   for(int j = ZQ_SEQ_LEN; j >= 1; j--)
   {
      double atr = at[j];
      double hourf = 0;
      MqlDateTime mt; TimeToStruct(tm[j], mt);
      hourf = mt.hour + mt.min/60.0;

      // cửa sổ RANGE_N nến kết thúc tại j (khớp pandas rolling(N) tại nến i)
      double hh = h[j], ll = l[j];
      for(int w = j; w < j + ZQ_RANGE_N; w++){ if(h[w]>hh) hh=h[w]; if(l[w]<ll) ll=l[w]; }

      double f[ZQ_NFEAT];
      f[0]  = MathLog(c[j] / c[j+1]);             // ret1
      f[1]  = MathLog(c[j] / c[j+4]);             // ret4
      f[2]  = (c[j] - o[j]) / (atr + eps);        // body_atr
      f[3]  = (h[j] - l[j]) / (atr + eps);        // range_atr
      f[4]  = (c[j] - ef[j]) / (atr + eps);       // close_ema_f
      f[5]  = (ef[j] - es[j]) / (atr + eps);      // ema_f_ema_s
      f[6]  = rs[j] / 100.0;                      // rsi
      f[7]  = atr / (c[j] + eps);                 // atr_close
      f[8]  = MathSin(2*M_PI*hourf/24.0);         // hour_sin
      f[9]  = MathCos(2*M_PI*hourf/24.0);         // hour_cos
      f[10] = (c[j] - ll) / (hh - ll + eps) - 0.5;// ext_pos
      f[11] = (c[j] - e2[j]) / (atr + eps);       // ema200_dist

      int seqpos = ZQ_SEQ_LEN - j;
      for(int k = 0; k < ZQ_NFEAT; k++)
         inp[seqpos*ZQ_NFEAT + k] = (float)((f[k] - ZQ_MEAN[k]) / ZQ_STD[k]);
   }

   float out[];
   ArrayResize(out, ZQ_NCLASS);
   if(!OnnxRun(gModel, ONNX_NO_CONVERSION, inp, out)){ Print("OnnxRun lỗi ", GetLastError()); return 0; }

   // out = [P(NoGo), P(Go)]. Vào lệnh khi P(Go) đủ cao; hướng lấy từ trend EMA.
   double pGo = out[1];
   if(pGo < InpConfThreshold) return 0;
   if(ef[1] > es[1]) return  1;   // trend lên -> Long
   if(ef[1] < es[1]) return -1;   // trend xuống -> Short
   return 0;
}

//======================================================================
//======================================================================
//  Circuit-breaker: bảo vệ tài khoản. Trả false = không mở lệnh mới.
//======================================================================
bool RiskGuardOk()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(gStartEquity <= 0) gStartEquity = eq;

   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   if(t.day_of_year != gDayOfYear){ gDayOfYear = t.day_of_year; gDayStartEquity = eq; }

   if(InpUseEquityStop && eq <= gStartEquity*(1.0 - InpEquityStopPct/100.0)){
      if(!gHalted){ CloseAllMy(); gHalted = true;
                    Print("EQUITY STOP kích hoạt: đóng toàn bộ & dừng giao dịch."); }
      return false;
   }
   if(gHalted) return false;
   if(InpUseDailyLoss && eq <= gDayStartEquity*(1.0 - InpMaxDailyLossPct/100.0)) return false;
   return true;
}

void CloseAllMy()
{
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong tk=PositionGetTicket(i);
      if(PositionSelectByTicket(tk) && PositionGetInteger(POSITION_MAGIC)==InpMagic
         && PositionGetString(POSITION_SYMBOL)==_Symbol)
         trade.PositionClose(tk);
   }
}

bool PassFilters()
{
   double spread = SymbolInfoDouble(_Symbol,SYMBOL_ASK) - SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(spread > InpMaxSpreadUSD) return false;
   if(InpUseTimeFilter){
      MqlDateTime t; TimeToStruct(TimeCurrent(), t);
      if(t.hour < InpStartHour || t.hour >= InpEndHour) return false;
      if(InpBlockFriLate && t.day_of_week==5 && t.hour>=20) return false;
   }
   return true;
}

//======================================================================
void OpenTrade(int dir)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double atr[1]; ArraySetAsSeries(atr,true);
   if(CopyBuffer(hATRstop,0,1,1,atr) < 1) return;
   double slDist = InpUseATRStop ? (atr[0]*InpATR_SL_Mult) : InpFixedStopUSD;
   double tpDist = InpUseATRTP   ? (atr[0]*InpATR_TP_Mult) : InpTakeProfitUSD;
   double lot    = CalcLot(slDist);
   if(lot <= 0) return;

   if(dir > 0) trade.Buy (lot,_Symbol,ask, ask-slDist, ask+tpDist, "ZerqonONNX");
   else        trade.Sell(lot,_Symbol,bid, bid+slDist, bid-tpDist, "ZerqonONNX");
}

//======================================================================
double CalcLot(double slDist)
{
   double lot = InpFixedLot;
   if(InpUseRiskSizing && slDist>0 && gTickSize>0 && gTickValue>0){
      double riskMoney  = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskLevel;
      double lossPerLot = (slDist / gTickSize) * gTickValue;
      if(lossPerLot > 0) lot = riskMoney / lossPerLot;
   }
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot/step)*step;
   lot = MathMax(minL, MathMin(lot, MathMin(maxL, InpMaxLot)));
   return lot;
}

int CountMyPositions()
{
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong tk=PositionGetTicket(i);
      if(PositionSelectByTicket(tk) && PositionGetInteger(POSITION_MAGIC)==InpMagic
         && PositionGetString(POSITION_SYMBOL)==_Symbol) n++;
   }
   return n;
}

void ManageOpenPositions()
{
   if(!InpUseBreakeven && !InpUseTrailing) return;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong tk=PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      long   type=PositionGetInteger(POSITION_TYPE);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double newSL=curSL;
      if(type==POSITION_TYPE_BUY){
         double profit=bid-open;
         if(InpUseBreakeven && profit>=InpBE_TriggerUSD) newSL=MathMax(newSL,open+InpBE_LockUSD);
         if(InpUseTrailing  && profit>=InpTrailStartUSD) newSL=MathMax(newSL,bid-InpTrailDistUSD);
         if(newSL>curSL+gPoint) trade.PositionModify(tk,NormalizeDouble(newSL,_Digits),tp);
      } else if(type==POSITION_TYPE_SELL){
         double profit=open-ask;
         if(InpUseBreakeven && profit>=InpBE_TriggerUSD) newSL=(curSL==0)?open-InpBE_LockUSD:MathMin(newSL,open-InpBE_LockUSD);
         if(InpUseTrailing  && profit>=InpTrailStartUSD) newSL=(newSL==0)?ask+InpTrailDistUSD:MathMin(newSL,ask+InpTrailDistUSD);
         if(newSL<curSL-gPoint || curSL==0) trade.PositionModify(tk,NormalizeDouble(newSL,_Digits),tp);
      }
   }
}
//+------------------------------------------------------------------+
