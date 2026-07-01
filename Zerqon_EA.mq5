//+------------------------------------------------------------------+
//|                                              RegressScalp_EA.mq5  |
//|        Linear Regression Mean Reversion Scalper (XAUUSD)         |
//|        Fixed-lot grid + Basket TP/SL (USD)  -  MT5 / CTrade     |
//+------------------------------------------------------------------+
#property copyright "RegressScalp_EA"
#property version   "1.03"
#property strict
#property description "Mean-reversion scalper around a dynamic linear regression channel. Khoang cach nhap bang USD."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//============================ INPUTS =================================
// LƯU Ý: Mọi khoảng cách dưới đây nhập bằng USD (giá vàng di chuyển bao nhiêu đô),
// KHÔNG còn dùng Points -> không phụ thuộc sàn 2 hay 3 digit.
input group "--- General Settings ---"
input string      InpEAName          = "RegressScalp_EA"; // EA Name
input ulong       InpMagicNumber     = 8823719;           // Magic Number
input double      InpMaxSpreadUSD    = 0.5;               // Spread tối đa cho phép ($) - vd 0.5 = $0.50
input bool        InpDebug           = true;              // Bật debug (in giá trị kênh + spread lên chart)

input group "--- Strategy Settings ---"
input int         InpRegrPeriod      = 50;                // Số nến tính hồi quy
input double      InpStdDevMultiplier= 1.5;               // Hệ số StdDev (giảm để dễ chạm biên)
input double      InpOuterBufferUSD  = 0.0;               // Vùng đệm ngoài kênh ($) - để 0 để xem tần suất vào lệnh

input group "--- Money Management ---"
input double      InpFixedLot        = 0.01;              // Fixed Lot Size
input int         InpMaxPositions    = 5;                 // Max Concurrent Positions
input double      InpGridDistanceUSD = 10.0;              // Khoảng cách nhồi lệnh ($) - vd 10 = $10
input double      InpBasketTP_USD    = 4.0;               // Chốt lời rổ lệnh ($ giá di chuyển có lợi)
input double      InpBasketSL_USD    = 30.0;              // Cắt lỗ rổ lệnh ($ giá đi ngược)

input group "--- Risk Protection ---"
input double      InpCooldownHours   = 6.0;               // Sau khi chạm SL khẩn cấp, ngừng vào lệnh mới (giờ)
input double      InpMaxSlopeUSD     = 0.15;              // Dừng vào lệnh nếu |độ dốc| > mức này ($/nến). 0 = tắt

input group "--- Time Filter (né phiên biến động) ---"
input bool        InpUseTimeFilter   = true;             // Bật lọc khung giờ (vd né phiên Âu mở cửa)
input int         InpBrokerGMTOffset = 3;                // Múi giờ server broker (GMT+?). Mùa hè thường +3, đông +2
input int         InpBlockStartHour  = 13;               // Giờ bắt đầu né (GIỜ VIỆT NAM, GMT+7)
input int         InpBlockStartMin   = 30;               // Phút bắt đầu né
input int         InpBlockEndHour    = 15;               // Giờ kết thúc né (GIỜ VIỆT NAM, GMT+7)
input int         InpBlockEndMin     = 30;               // Phút kết thúc né

//============================ GLOBALS ================================
CTrade          trade;
CPositionInfo   posInfo;
datetime        g_cooldownUntil = 0;   // chặn vào lệnh mới đến thời điểm này (sau SL khẩn cấp)

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   PrintFormat("INIT %s | Digits=%d Point=%.5f | Spread(now)=$%.2f MaxSpread=$%.2f | MinLot=%.2f Step=%.2f",
               _Symbol,
               (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS),
               _Point, (ask - bid), InpMaxSpreadUSD,
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP));

   if(InpRegrPeriod < 5)
   {
      Print("Error: Regression Period too short.");
      return(INIT_FAILED);
   }

   // Khôi phục cooldown nếu EA bị nạp lại trong lúc đang bị khóa
   if(GlobalVariableCheck(CooldownVarName()))
   {
      g_cooldownUntil = (datetime)GlobalVariableGet(CooldownVarName());
      if(TimeCurrent() < g_cooldownUntil)
         PrintFormat("COOLDOWN còn hiệu lực đến %s", TimeToString(g_cooldownUntil, TIME_DATE|TIME_MINUTES));
   }

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // 1. Spread tính bằng USD (chênh lệch giá thực)
   double spreadUSD = ask - bid;

   // 2. Kiểm tra mục tiêu Basket TP/SL (theo USD)
   if(CheckBasketTargets(bid, ask))
      return;

   // 3. Tính toán kênh hồi quy tuyến tính
   double centerLine = 0, upperChannel = 0, lowerChannel = 0, slope = 0;
   bool   channelOK = CalculateRegressionChannel(InpRegrPeriod, InpStdDevMultiplier, centerLine, upperChannel, lowerChannel, slope);
   bool   fastMarket = (InpMaxSlopeUSD > 0 && MathAbs(slope) > InpMaxSlopeUSD);

   // --- DEBUG: hiển thị tại sao vào/không vào lệnh ---
   if(InpDebug)
   {
      string cdStatus;
      if(TimeCurrent() < g_cooldownUntil)
         cdStatus = StringFormat("<<< COOLDOWN đến %s", TimeToString(g_cooldownUntil, TIME_DATE|TIME_MINUTES));
      else if(fastMarket)
         cdStatus = "<<< THỊ TRƯỜNG QUÁ DỐC - tạm dừng";
      else if(InTradingBlackout())
         cdStatus = StringFormat("<<< NÉ KHUNG GIỜ %02d:%02d-%02d:%02d", InpBlockStartHour, InpBlockStartMin, InpBlockEndHour, InpBlockEndMin);
      else
         cdStatus = "sẵn sàng";
      datetime vnNow = TimeCurrent() + (datetime)((7 - InpBrokerGMTOffset) * 3600);
      Comment(StringFormat(
         "%s | Server: %s | VN: %s\nSpread=$%.2f (max $%.2f) %s\nChannel: lower=%.3f  center=%.3f  upper=%.3f\nSlope=$%.3f/nến (max $%.2f)\nAsk=%.3f  Bid=%.3f\nBUY khi Ask < %.3f | SELL khi Bid > %.3f\nTrạng thái: %s",
         InpEAName,
         TimeToString(TimeCurrent(), TIME_MINUTES),
         TimeToString(vnNow, TIME_MINUTES),
         spreadUSD, InpMaxSpreadUSD,
         (spreadUSD > InpMaxSpreadUSD ? "<<< SPREAD CHẶN LỆNH" : "OK"),
         lowerChannel, centerLine, upperChannel,
         slope, InpMaxSlopeUSD,
         ask, bid,
         lowerChannel - InpOuterBufferUSD, upperChannel + InpOuterBufferUSD, cdStatus));
   }

   // Lọc spread + kiểm tra kênh hợp lệ (sau khi đã in debug)
   if(spreadUSD > InpMaxSpreadUSD) return;
   if(!channelOK) return;

   // CẦU DAO NGẮT: sau khi chạm SL khẩn cấp, không mở lệnh mới đến hết cooldown.
   // (Các vị thế đang mở vẫn được CheckBasketTargets() ở trên quản lý bình thường.)
   if(TimeCurrent() < g_cooldownUntil)
      return;

   // LỌC ĐỘ DỐC: giá đang chạy quá nhanh một chiều -> không bắt ngược, chỉ quản lý lệnh cũ.
   if(fastMarket)
      return;

   // LỌC KHUNG GIỜ: né phiên biến động mạnh -> không mở lệnh mới.
   if(InTradingBlackout())
      return;

   // Phân loại số lượng vị thế đang mở
   int buyCount = 0, sellCount = 0;
   double lastBuyPrice = 0, lastSellPrice = 0;
   GetPositionStats(buyCount, sellCount, lastBuyPrice, lastSellPrice);

   int totalPositions = buyCount + sellCount;
   if(totalPositions >= InpMaxPositions)
      return;

   double lot = NormalizeLot(InpFixedLot);

   // 4. LOGIC KÍCH HOẠT VÀO LỆNH
   // --- LỆNH BUY (giá rớt sâu dưới đáy kênh) ---
   if(ask < (lowerChannel - InpOuterBufferUSD))
   {
      if(buyCount == 0)
      {
         trade.Buy(lot, _Symbol, 0, 0, 0, "Initial Buy");
      }
      else if(buyCount < InpMaxPositions && (lastBuyPrice - ask) >= InpGridDistanceUSD)
      {
         trade.Buy(lot, _Symbol, 0, 0, 0, StringFormat("Grid Buy #%d", buyCount+1));
      }
   }

   // --- LỆNH SELL (giá tăng vọt quá đỉnh kênh) ---
   if(bid > (upperChannel + InpOuterBufferUSD))
   {
      if(sellCount == 0)
      {
         trade.Sell(lot, _Symbol, 0, 0, 0, "Initial Sell");
      }
      else if(sellCount < InpMaxPositions && (bid - lastSellPrice) >= InpGridDistanceUSD)
      {
         trade.Sell(lot, _Symbol, 0, 0, 0, StringFormat("Grid Sell #%d", sellCount+1));
      }
   }
}

//+------------------------------------------------------------------+
//| Tính toán kênh hồi quy tuyến tính (least squares)                |
//+------------------------------------------------------------------+
bool CalculateRegressionChannel(int period, double stdDevMult, double &center, double &upper, double &lower, double &outSlope)
{
   double closePrices[];
   ArraySetAsSeries(closePrices, true);
   if(CopyClose(_Symbol, _Period, 0, period, closePrices) < period)
      return(false);

   double sumX  = 0;
   double sumXX = 0;
   double sumY  = 0;
   double sumXY = 0;

   // Trục thời gian t chạy tăng dần từ quá khứ (t=0) đến hiện tại (t=period-1)
   for(int i = 0; i < period; i++)
   {
      int t = period - 1 - i;
      double price = closePrices[i];

      sumX  += t;
      sumXX += (double)t * t;
      sumY  += price;
      sumXY += (double)t * price;
   }

   double denominator = (period * sumXX) - (sumX * sumX);
   if(denominator == 0) return(false);

   double slope     = ((period * sumXY) - (sumX * sumY)) / denominator;
   double intercept = (sumY - (slope * sumX)) / period;

   outSlope = slope; // độ dốc = giá thay đổi trên mỗi cây nến (USD/nến)

   // Giá trị đường hồi quy tại nến hiện tại (t = period - 1)
   center = intercept + slope * (period - 1);

   // Độ lệch chuẩn của phần dư quanh đường hồi quy
   double varianceSum = 0;
   for(int i = 0; i < period; i++)
   {
      int t = period - 1 - i;
      double regPrice = intercept + slope * t;
      varianceSum += MathPow(closePrices[i] - regPrice, 2);
   }

   double stdDev = MathSqrt(varianceSum / period);

   upper = center + (stdDev * stdDevMult);
   lower = center - (stdDev * stdDevMult);

   return(true);
}

//+------------------------------------------------------------------+
//| Thống kê trạng thái lệnh của Magic Number                        |
//+------------------------------------------------------------------+
void GetPositionStats(int &buyCount, int &sellCount, double &lastBuyPrice, double &lastSellPrice)
{
   buyCount = 0;
   sellCount = 0;
   lastBuyPrice = 0;
   lastSellPrice = 0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic() != (long)InpMagicNumber) continue;

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
      {
         buyCount++;
         if(lastBuyPrice == 0 || posInfo.PriceOpen() < lastBuyPrice)
            lastBuyPrice = posInfo.PriceOpen(); // Giá Buy thấp nhất làm mốc Grid
      }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
      {
         sellCount++;
         if(lastSellPrice == 0 || posInfo.PriceOpen() > lastSellPrice)
            lastSellPrice = posInfo.PriceOpen(); // Giá Sell cao nhất làm mốc Grid
      }
   }
}

//+------------------------------------------------------------------+
//| Kiểm tra mục tiêu Basket bằng USD (giá di chuyển), theo từng hướng|
//+------------------------------------------------------------------+
bool CheckBasketTargets(double currentBid, double currentAsk)
{
   double totalBuyLot = 0, totalSellLot = 0;
   double buyWeightedPrice = 0, sellWeightedPrice = 0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic() != (long)InpMagicNumber) continue;

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
      {
         buyWeightedPrice += posInfo.PriceOpen() * posInfo.Volume();
         totalBuyLot      += posInfo.Volume();
      }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
      {
         sellWeightedPrice += posInfo.PriceOpen() * posInfo.Volume();
         totalSellLot      += posInfo.Volume();
      }
   }

   // Kiểm tra rổ Buy (lời/lỗ tính bằng USD = chênh lệch giá)
   if(totalBuyLot > 0)
   {
      double avgBuyPrice = buyWeightedPrice / totalBuyLot;
      double profitUSD   = currentBid - avgBuyPrice; // dương = đang lời

      if(profitUSD >= InpBasketTP_USD)
      {
         PrintFormat("Basket BUY TP Hit. Profit = $%.2f", profitUSD);
         ClosePositionsByDirection(POSITION_TYPE_BUY);
         return(true);
      }
      if(profitUSD <= -InpBasketSL_USD)
      {
         PrintFormat("Basket BUY Emergency SL Hit. Loss = $%.2f", profitUSD);
         ClosePositionsByDirection(POSITION_TYPE_BUY);
         StartCooldown();
         return(true);
      }
   }

   // Kiểm tra rổ Sell
   if(totalSellLot > 0)
   {
      double avgSellPrice = sellWeightedPrice / totalSellLot;
      double profitUSD    = avgSellPrice - currentAsk; // dương = đang lời

      if(profitUSD >= InpBasketTP_USD)
      {
         PrintFormat("Basket SELL TP Hit. Profit = $%.2f", profitUSD);
         ClosePositionsByDirection(POSITION_TYPE_SELL);
         return(true);
      }
      if(profitUSD <= -InpBasketSL_USD)
      {
         PrintFormat("Basket SELL Emergency SL Hit. Loss = $%.2f", profitUSD);
         ClosePositionsByDirection(POSITION_TYPE_SELL);
         StartCooldown();
         return(true);
      }
   }

   return(false);
}

//+------------------------------------------------------------------+
//| Kiểm tra có đang trong khung giờ né giao dịch không (giờ server) |
//+------------------------------------------------------------------+
bool InTradingBlackout()
{
   if(!InpUseTimeFilter) return(false);

   // Đổi giờ server -> giờ Việt Nam (GMT+7) để so với khung giờ người dùng nhập.
   datetime vnTime = TimeCurrent() + (datetime)((7 - InpBrokerGMTOffset) * 3600);

   MqlDateTime dt;
   TimeToStruct(vnTime, dt);
   int nowMin   = dt.hour * 60 + dt.min;
   int startMin = InpBlockStartHour * 60 + InpBlockStartMin;
   int endMin   = InpBlockEndHour   * 60 + InpBlockEndMin;

   if(startMin == endMin) return(false); // khung rỗng -> không né

   if(startMin < endMin)
      return(nowMin >= startMin && nowMin < endMin);   // khung trong ngày
   else
      return(nowMin >= startMin || nowMin < endMin);   // khung vắt qua nửa đêm
}

//+------------------------------------------------------------------+
//| Tên biến toàn cục lưu mốc cooldown (riêng theo symbol + magic)   |
//+------------------------------------------------------------------+
string CooldownVarName()
{
   return(StringFormat("RSC_CD_%s_%I64u", _Symbol, InpMagicNumber));
}

//+------------------------------------------------------------------+
//| Kích hoạt cooldown sau khi chạm SL khẩn cấp                      |
//+------------------------------------------------------------------+
void StartCooldown()
{
   if(InpCooldownHours <= 0) return;

   g_cooldownUntil = TimeCurrent() + (datetime)(InpCooldownHours * 3600.0);
   GlobalVariableSet(CooldownVarName(), (double)g_cooldownUntil); // lưu để sống sót qua restart
   PrintFormat("COOLDOWN bật: ngừng vào lệnh mới đến %s",
               TimeToString(g_cooldownUntil, TIME_DATE|TIME_MINUTES));
}

//+------------------------------------------------------------------+
//| Chuẩn hóa lot theo step/min/max của broker                       |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = 0.01;
   lot = MathRound(lot / step) * step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return(lot);
}

//+------------------------------------------------------------------+
//| Đóng lệnh theo hướng chỉ định                                    |
//+------------------------------------------------------------------+
void ClosePositionsByDirection(ENUM_POSITION_TYPE posType)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic() != (long)InpMagicNumber) continue;
      if(posInfo.PositionType() != posType) continue;

      ulong ticket = posInfo.Ticket();
      if(!trade.PositionClose(ticket))
         PrintFormat("Close failed ticket=%I64u retcode=%d", ticket, trade.ResultRetcode());
   }
}
//+------------------------------------------------------------------+
