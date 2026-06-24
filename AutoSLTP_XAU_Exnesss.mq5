
//+------------------------------------------------------------------+
//|                                               QuantumQuan_v0.1   |
//|                    Basket Take Profit / Stop Loss Protector      |
//+------------------------------------------------------------------+
#include <Trade/Trade.mqh>

CTrade trade;

//================ INPUT ==================
input string TradeSymbol   = "XAUUSDm"; // Symbol cần quản lý
input double BasketTPUSD   = 10.0;      // Chốt lời cả giỏ
input double BasketSLUSD   = 20.0;      // Cắt lỗ cả giỏ
input bool   EnableTP      = true;
input bool   EnableSL      = true;
//=========================================

//--------------------------------------------------
double GetBasketProfit()
{
   double totalProfit = 0.0;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(PositionSelectByTicket(ticket))
      {
         string symbol = PositionGetString(POSITION_SYMBOL);

         if(symbol == TradeSymbol)
         {
            totalProfit += PositionGetDouble(POSITION_PROFIT);
         }
      }
   }

   return totalProfit;
}

//--------------------------------------------------
int CountPositions()
{
   int count = 0;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == TradeSymbol)
            count++;
      }
   }

   return count;
}

//--------------------------------------------------
void CloseAllPositions()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(PositionSelectByTicket(ticket))
      {
         string symbol = PositionGetString(POSITION_SYMBOL);

         if(symbol == TradeSymbol)
         {
            trade.PositionClose(ticket);
         }
      }
   }
}

//--------------------------------------------------
void OnTick()
{
   int totalPos = CountPositions();

   if(totalPos == 0)
      return;

   double basketProfit = GetBasketProfit();

   Comment(
      "Quantum Quan v0.1\n",
      "Symbol: ", TradeSymbol, "\n",
      "Positions: ", totalPos, "\n",
      "Basket Profit: $", DoubleToString(basketProfit,2), "\n",
      "TP Basket: $", DoubleToString(BasketTPUSD,2), "\n",
      "SL Basket: -$", DoubleToString(BasketSLUSD,2)
   );

   // Basket Take Profit
   if(EnableTP && basketProfit >= BasketTPUSD)
   {
      Print("Basket TP reached: ", basketProfit);
      CloseAllPositions();
      return;
   }

   // Basket Stop Loss
   if(EnableSL && basketProfit <= -BasketSLUSD)
   {
      Print("Basket SL reached: ", basketProfit);
      CloseAllPositions();
      return;
   }
}
