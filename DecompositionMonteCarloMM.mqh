//+------------------------------------------------------------------+
//| DecompositionMonteCarloMM.mqh – 単数列分解管理モンテカルロ法     |
//+------------------------------------------------------------------+
#property strict
#define _MIN(a,b) ((a)<(b)?(a):(b))

/* 配列ユーティリティ */
void Erase(int &a[],int p){int n=ArraySize(a); if(p<0||p>=n) return;
                           for(int i=p;i<n-1;i++) a[i]=a[i+1];
                           ArrayResize(a,n-1);}
void Ins  (int &a[],int p,int v){int n=ArraySize(a); ArrayResize(a,n+1);
                                 for(int i=n;i>p;i--) a[i]=a[i-1]; a[p]=v;}

/*──────────────────────────────────────────*/
class CDecompMC
{
private:
   int seq[]; int stock; int streak;

/*── A 平均 (先頭 0) ──*/
   void avgA(){
      Erase(seq,0);
      int  n   = ArraySize(seq);
      long sum = 0; for(int i=0;i<n;i++) sum += seq[i];
      int  q   = (int)(sum / n);
      int  r   = (int)(sum % n);
      for(int i=0;i<n;i++) seq[i] = q;
      if(r) seq[0] += r;
      Ins(seq,0,0);
   }

/*── B 平均 (先頭≠0) ──*/
   void avgB(){
      int  n   = ArraySize(seq);
      long sum = 0; for(int i=0;i<n;i++) sum += seq[i];
      int  q   = (int)(sum / n);
      int  r   = (int)(sum % n);
      for(int i=0;i<n;i++) seq[i] = q;
      if(r && n>=2) seq[1] += r;
   }

/*── 0 生成 ──*/
   void zeroGen(){
      if(seq[0]==0) return;
      int red = seq[0]; seq[0]=0;
      int sub = ArraySize(seq)-1;

      // 残り要素より少ない場合は2番目へ加算のみ
      if(red<sub){
         seq[1] += red;
         return;                                 // 加算のみで終了
      }else{
         long tot = red; for(int i=1;i<ArraySize(seq);i++) tot += seq[i];
         int q = (int)(tot / sub), r = (int)(tot % sub);
         Erase(seq,0); for(int i=0;i<ArraySize(seq);i++) seq[i]=q;
         if(r) seq[0]+=r; Ins(seq,0,0);          // 再配布のみで整形完了
      }
   }

   int gm()const{ return (streak<=1)?1:(streak==2)?1:(streak==3)?2:(streak==4)?3:5; }

/*── WIN ──*/
   void winStep(){
      int n = ArraySize(seq);
      // 条件成立時は連勝数+1、不成立時は現状維持
      if(n==2 && seq[0]==0 && seq[1]==1)
         streak++;

      if(n==2){ seq[0]=0; seq[1]=1; }
      else if(n==3){
         int center = seq[1];            // 中央の値を取得
         Erase(seq,0);                   // 先頭を削除
         Erase(seq,ArraySize(seq)-1);    // 末尾を削除
         int left  = center/2;           // 左値を計算
         int right = left + center%2;    // 右値を計算
         seq[0] = left;                  // 左値を設定
         Ins(seq,1,right);               // 右値を挿入
      }else{
         Erase(seq,0); Erase(seq,ArraySize(seq)-1);
      }
      if(seq[0]==0) avgA(); else avgB();      // ← if/else で呼び出し
   }

/*── LOSE ──*/
   void loseStep(){
      if(streak>=6) stock += 4*streak - 21; // 連勝数が6以上ならストック加算
      streak = 0;                            // 敗北時は連勝数リセット

      Ins(seq,ArraySize(seq), seq[0]+seq[ArraySize(seq)-1]);
      if(seq[0]==0) avgA(); else avgB();      // ← ここも if/else

      /* ストック消費：先頭のみ 0 化 */
      if(seq[0]<=stock){
         int use = seq[0];
         stock  -= use;                        // ストックから差し引く
         seq[0]  = 0;                          // 先頭を 0 に設定
      }

      if(seq[0]>0) zeroGen();
   }

public:
   void Init(){ ArrayResize(seq,2); seq[0]=0; seq[1]=1; stock=streak=0; }
   void OnTrade(bool win){ if(win) winStep(); else loseStep(); }

   double NextLot() const{
      int u = seq[0] + seq[ArraySize(seq)-1];
      return (double)u * gm();                // 基本ベット額=1
   }

   /* デバッグ用 */
   string Seq(){string s="";for(int i=0;i<ArraySize(seq);i++){if(i)s+=",";s+=IntegerToString(seq[i]);}return s;}
   int    Stock(){ return stock; }
};
