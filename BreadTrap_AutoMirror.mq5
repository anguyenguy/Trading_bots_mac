#property strict

#include <Trade/Trade.mqh>

input double InpStopLossDistance = 3.0;     // Khoang cach SL theo gia
input double InpTakeProfitDistance = 3.5;   // Khoang cach TP theo gia
input double InpPendingSpace = 1.0;         // Khoang cach pending doi ung
input bool   InpHandleManualOnly = true;    // Chi xu ly lenh tay (magic = 0)
input ulong  InpExpertMagic = 26062026;     // Magic number cho pending do EA tao
input int    InpSlippagePoints = 30;        // Do lech gia cho phep khi modify/dat lenh

CTrade trade;

string BuildPendingComment(const ulong positionTicket)
{
   return "BTB_LINK_" + (string)positionTicket;
}

bool ExtractLinkedTicket(const string comment, ulong &positionTicket)
{
   string prefix = "BTB_LINK_";
   int prefixLen = (int)StringLen(prefix);

   if(StringLen(comment) <= prefixLen)
      return false;

   if(StringSubstr(comment, 0, prefixLen) != prefix)
      return false;

   positionTicket = (ulong)StringToInteger(StringSubstr(comment, prefixLen));
   return (positionTicket > 0);
}

double NormalizePrice(const double price)
{
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

bool IsManagedPosition()
{
   long magic = PositionGetInteger(POSITION_MAGIC);
   if(InpHandleManualOnly)
      return (magic == 0);

   return (magic != (long)InpExpertMagic);
}

bool CalculatePositionStops(const ENUM_POSITION_TYPE positionType,
                            const double entryPrice,
                            double &sl,
                            double &tp)
{
   if(positionType == POSITION_TYPE_BUY)
   {
      sl = NormalizePrice(entryPrice - InpStopLossDistance);
      tp = NormalizePrice(entryPrice + InpTakeProfitDistance);
      return true;
   }

   if(positionType == POSITION_TYPE_SELL)
   {
      sl = NormalizePrice(entryPrice + InpStopLossDistance);
      tp = NormalizePrice(entryPrice - InpTakeProfitDistance);
      return true;
   }

   return false;
}

bool CalculatePendingOrder(ENUM_POSITION_TYPE positionType,
                           const double positionEntry,
                           ENUM_ORDER_TYPE &orderType,
                           double &orderPrice,
                           double &sl,
                           double &tp)
{
   if(positionType == POSITION_TYPE_BUY)
   {
      orderType = ORDER_TYPE_SELL_LIMIT;
      orderPrice = NormalizePrice(positionEntry + InpPendingSpace);
      sl = NormalizePrice(orderPrice + InpStopLossDistance);
      tp = NormalizePrice(orderPrice - InpTakeProfitDistance);
      return true;
   }

   if(positionType == POSITION_TYPE_SELL)
   {
      orderType = ORDER_TYPE_BUY_LIMIT;
      orderPrice = NormalizePrice(positionEntry - InpPendingSpace);
      sl = NormalizePrice(orderPrice - InpStopLossDistance);
      tp = NormalizePrice(orderPrice + InpTakeProfitDistance);
      return true;
   }

   return false;
}

bool HasLinkedChildPosition(const ulong rootPositionTicket)
{
   int totalPositions = PositionsTotal();

   for(int i = totalPositions - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpExpertMagic)
         continue;

      ulong linkedTicket = 0;
      if(!ExtractLinkedTicket(PositionGetString(POSITION_COMMENT), linkedTicket))
         continue;

      if(linkedTicket == rootPositionTicket)
         return true;
   }

   return false;
}

bool HasLinkedPendingOrder(const ulong positionTicket)
{
   string expectedComment = BuildPendingComment(positionTicket);
   int totalOrders = OrdersTotal();

   for(int i = 0; i < totalOrders; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;

      if(!OrderSelect(ticket))
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpExpertMagic)
         continue;

      if(OrderGetString(ORDER_COMMENT) == expectedComment)
         return true;
   }

   return false;
}

bool HasActivePair(const ulong rootPositionTicket)
{
   if(HasLinkedPendingOrder(rootPositionTicket))
      return true;

   if(HasLinkedChildPosition(rootPositionTicket))
      return true;

   return false;
}

bool UpdatePositionStopsIfNeeded(const ulong positionTicket)
{
   if(!PositionSelectByTicket(positionTicket))
      return false;

   ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSl = PositionGetDouble(POSITION_SL);
   double currentTp = PositionGetDouble(POSITION_TP);
   double targetSl = 0.0;
   double targetTp = 0.0;

   if(!CalculatePositionStops(positionType, entryPrice, targetSl, targetTp))
      return false;

   if(MathAbs(currentSl - targetSl) < (_Point * 0.5) &&
      MathAbs(currentTp - targetTp) < (_Point * 0.5))
      return true;

   trade.SetExpertMagicNumber(InpExpertMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   if(trade.PositionModify(positionTicket, targetSl, targetTp))
      return true;

   Print("Khong the cap nhat SL/TP cho position #", positionTicket,
         ". Retcode=", trade.ResultRetcode(),
         ", message=", trade.ResultRetcodeDescription());
   return false;
}

bool PlaceLinkedPendingOrder(const ulong positionTicket)
{
   if(!PositionSelectByTicket(positionTicket))
      return false;

   ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double positionEntry = PositionGetDouble(POSITION_PRICE_OPEN);
   double volume = PositionGetDouble(POSITION_VOLUME);
   ENUM_ORDER_TYPE orderType;
   double orderPrice = 0.0;
   double sl = 0.0;
   double tp = 0.0;

   if(!CalculatePendingOrder(positionType, positionEntry, orderType, orderPrice, sl, tp))
      return false;

   trade.SetExpertMagicNumber(InpExpertMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   string comment = BuildPendingComment(positionTicket);
   bool placed = false;

   if(orderType == ORDER_TYPE_SELL_LIMIT)
      placed = trade.SellLimit(volume, orderPrice, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
   else if(orderType == ORDER_TYPE_BUY_LIMIT)
      placed = trade.BuyLimit(volume, orderPrice, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment);

   if(placed)
      return true;

   Print("Khong the dat pending doi ung cho position #", positionTicket,
         ". Retcode=", trade.ResultRetcode(),
         ", message=", trade.ResultRetcodeDescription());
   return false;
}

bool CancelPendingOrderByTicket(const ulong orderTicket)
{
   trade.SetExpertMagicNumber(InpExpertMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   if(trade.OrderDelete(orderTicket))
      return true;

   Print("Khong the xoa pending #", orderTicket,
         ". Retcode=", trade.ResultRetcode(),
         ", message=", trade.ResultRetcodeDescription());
   return false;
}

bool RootPositionStillExists(const ulong rootPositionTicket)
{
   if(!PositionSelectByTicket(rootPositionTicket))
      return false;

   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return false;

   return IsManagedPosition();
}

void CleanupOrphanPendingOrders()
{
   int totalOrders = OrdersTotal();

   for(int i = totalOrders - 1; i >= 0; i--)
   {
      ulong orderTicket = OrderGetTicket(i);
      if(orderTicket == 0)
         continue;

      if(!OrderSelect(orderTicket))
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpExpertMagic)
         continue;

      ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(orderType != ORDER_TYPE_BUY_LIMIT && orderType != ORDER_TYPE_SELL_LIMIT)
         continue;

      ulong linkedRootTicket = 0;
      if(!ExtractLinkedTicket(OrderGetString(ORDER_COMMENT), linkedRootTicket))
         continue;

      if(!RootPositionStillExists(linkedRootTicket))
         CancelPendingOrderByTicket(orderTicket);
   }
}

void ManageOpenPositions()
{
   CleanupOrphanPendingOrders();

   int totalPositions = PositionsTotal();

   for(int i = totalPositions - 1; i >= 0; i--)
   {
      ulong positionTicket = PositionGetTicket(i);
      if(positionTicket == 0)
         continue;

      if(!PositionSelectByTicket(positionTicket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(!IsManagedPosition())
         continue;

      UpdatePositionStopsIfNeeded(positionTicket);

      if(!HasActivePair(positionTicket))
         PlaceLinkedPendingOrder(positionTicket);
   }
}

int OnInit()
{
   if(InpStopLossDistance <= 0.0 || InpTakeProfitDistance <= 0.0 || InpPendingSpace <= 0.0)
   {
      Print("Thong so SL, TP va Space phai lon hon 0.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   trade.SetExpertMagicNumber(InpExpertMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   return(INIT_SUCCEEDED);
}

void OnTick()
{
   ManageOpenPositions();
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   ManageOpenPositions();
}
