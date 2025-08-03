#property strict

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
input double GridPips          = 100;   // TP/SL distance (pips)
input double EpsilonPips       = 1.0;   // Tolerance width (pips)
input double MaxSpreadPips     = 2.0;   // Max spread when placing orders
input bool   UseProtectedLimit = true;  // Use slippage-protected market orders after SL
input double SlippagePips      = 1.0;   // Maximum slippage for market orders
input bool   UseDistanceBand   = false; // Filter by distance band before ordering
input double MinDistancePips   = 50;    // Minimum distance (pips)
input double MaxDistancePips   = 55;    // Maximum distance (pips)
input bool   UseTickSnap       = false; // Enable tick snap reset
input int    SnapCooldownBars  = 2;     // Cooldown for tick snap (bars)
input double BaseLot           = 0.10;  // Base lot size (0.01 step)
input double MaxLot            = 1.50;  // User-defined maximum lot (0.01 step)
input int    MagicNumber       = 246810;// Magic number for order identification

// Derived values
double s;   // Half grid distance

bool IsStep(const double value,const double step)
{
   double scaled = value/step;
   return(MathAbs(scaled - MathRound(scaled)) < 1e-8);
}

double Pip()
{
   return((Digits == 3 || Digits == 5) ? 10 * Point : Point);
}

double PipsToPrice(const double p)
{
   return(p * Pip());
}

double PriceToPips(const double priceDiff)
{
   return(priceDiff / Pip());
}

double NormalizeLot(const double lotCandidate)
{
   double minLot  = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);

   double lot = lotCandidate;
   if(lotStep > 0)
      lot = MathRound(lot / lotStep) * lotStep;

   if(lot < minLot)
      lot = minLot;
   if(lot > maxLot)
      lot = maxLot;

   return(lot);
}

int OnInit()
{
   if(GridPips <= 0)
   {
      Print("GridPips must be greater than 0");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(EpsilonPips < 0)
   {
      Print("EpsilonPips must be non-negative");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(MaxSpreadPips < 0)
   {
      Print("MaxSpreadPips must be non-negative");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(SlippagePips < 0)
   {
      Print("SlippagePips must be non-negative");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(UseDistanceBand)
   {
      if(MinDistancePips < 0 || MaxDistancePips < MinDistancePips)
      {
         Print("Distance band parameters are invalid");
         return(INIT_PARAMETERS_INCORRECT);
      }
   }
   if(BaseLot <= 0 || !IsStep(BaseLot,0.01))
   {
      Print("BaseLot must be positive and in 0.01 increments");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(MaxLot <= 0 || !IsStep(MaxLot,0.01))
   {
      Print("MaxLot must be positive and in 0.01 increments");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(MaxLot < BaseLot)
   {
      Print("MaxLot must be greater than or equal to BaseLot");
      return(INIT_PARAMETERS_INCORRECT);
   }

   s   = GridPips / 2.0;

   return(INIT_SUCCEEDED);
}

void OnTick()
{
   // Placeholder for tick processing
}

void OnDeinit(const int reason)
{
   // Cleanup if necessary
}

