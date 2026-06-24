
//+------------------------------------------------------------------+
//| AutoSLTP_BTC_Exness.mq5                                          |
//| BTCUSDm Auto SL/TP by USD                                         |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"

input string TradeSymbol      = "BTCUSDm";
input double StopLossUSD      = 2.0;
input double TakeProfitUSD    = 3.5;

//------------------------------------------------------------------
// Kiểm tra có phải BTCUSD không
//------------------------------------------------------------------
bool IsTargetSymbol(string symbol)
{
   return (StringFind(symbol,"BTCUSD") >= 0);
}

//------------------------------------------------------------------
// Gắn SL TP cho position
//------------------------------------------------------------------
bool ApplySLTP(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return false;

   string symbol = PositionGetString(POSITION_SYMBOL);

   if(!IsTargetSymbol(symbol))
      return false;

   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);

   // Đã có SL hoặc TP thì bỏ qua
   if(currentSL > 0 || currentTP > 0)
      return false;

   double volume    = PositionGetDouble(POSITION_VOLUME);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);

   ENUM_POSITION_TYPE posType =
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   double tickValue =
      SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE);

   double tickSize =
      SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0)
      return false;

   double slDistance =
      (StopLossUSD / (tickValue * volume)) * tickSize;

   double tpDistance =
      (TakeProfitUSD / (tickValue * volume)) * tickSize;

   double newSL = 0;
   double newTP = 0;

   if(posType == POSITION_TYPE_BUY)
   {
      newSL = openPrice - slDistance;
      newTP = openPrice + tpDistance;
   }
   else
   {
      newSL = openPrice + slDistance;
      newTP = openPrice - tpDistance;
   }

   MqlTradeRequest request;
   MqlTradeResult  result;

   ZeroMemory(request);
   ZeroMemory(result);

   request.action   = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol   = symbol;
   request.sl       = NormalizeDouble(newSL,_Digits);
   request.tp       = NormalizeDouble(newTP,_Digits);

   bool sent = OrderSend(request,result);

   if(sent)
   {
      Print("BTC SL/TP applied. Ticket=",ticket,
            " SL=",request.sl,
            " TP=",request.tp);
   }
   else
   {
      Print("Failed. Error=",GetLastError());
   }

   return sent;
}

//------------------------------------------------------------------
// Main
//------------------------------------------------------------------
void OnTick()
{
   int total = PositionsTotal();

   for(int i=0;i<total;i++)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket > 0)
         ApplySLTP(ticket);
   }
}

