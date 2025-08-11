#property strict

input double SlippagePips = 1.0;

int MagicNumber = 246810;
double Pip = 0.0001;
int positionTicket[2];
int ticketBuyLim;

void Example()
{
   LogEvent("TP_REVERSE", "");
   LogEvent("SL_REENTRY", "");
   int slippage = (int)MathRound(SlippagePips * Pip / _Point);
   RetryOrder(false, positionTicket[SYSTEM_A], price);
   RetryOrder(false, ticketBuyLim, OP_BUYLIMIT, price);
   OrderSend(Symbol(), OP_BUY, 0.1, Ask, slippage, 0, 0, "", MagicNumber, 0, clrNONE);
}

