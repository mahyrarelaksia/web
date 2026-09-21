//+------------------------------------------------------------------+
//| EA_StopReverse_v240.mq5  v2.40                                   |
//| Logika:                                                          |
//| 1. Pasang Buy Stop & Sell Stop di atas dan bawah harga           |
//| 2. Jika salah satu tersentuh -> pending lainnya dihapus          |
//| 3. Hanya SL yang bergerak mengikuti harga (trailing)             |
//| 4. Jika SL kena -> pasang Buy Stop & Sell Stop baru, ulangi       |
//| 5. Opsional: pending baru hanya dipasang di jam sesi US          |
//| 6. Opsional: SL pindah ke harga buka (BEP) begitu posisi profit  |
//| 7. Lisensi: license key terkunci ke 1 nomor akun (+ masa berlaku)|
//| 8. Opsional: lot naik x2 setiap equity naik x10 dari modal acuan |
//| 9. Opsional: jarak otomatis ATR + filter pasar sepi              |
//+------------------------------------------------------------------+
#property copyright "EA Stop Reverse"
#property version   "2.40"

#include <Trade\Trade.mqh>

input group "=== Lisensi ==="
input string InpLisensi      = "";        // License key dari penjual

//--- WAJIB diganti sekali sebelum compile. Harus SAMA PERSIS dengan di generator.
//--- Pakai huruf dan angka saja, minimal 16 karakter, dan JANGAN dibagikan ke siapa pun.
const string LISENSI_RAHASIA = "GANTI-DENGAN-KATA-RAHASIA-KAMU";

input group "=== Order ==="
input double InpLot          = 0.01;      // Ukuran lot
input double InpJarakAwalPip = 10.0;      // Jarak Buy Stop / Sell Stop dari harga (pip)
input double InpSLPip        = 10.0;      // Jarak Stop Loss & trailing (pip)
input double InpTrailStepPip = 2.0;       // Minimal pergeseran SL (pip) - makin besar makin hemat
input int    InpDelayMenit   = 0;         // Tunggu setelah EA start (menit, 0 = langsung)
input double InpUkuranPip    = 0.0;       // Ukuran 1 pip dalam harga (0 = otomatis, emas = 0.1)
input ulong  InpMagic        = 20260919;  // Magic number (ID order milik EA ini)

input group "=== Jarak Otomatis ATR ==="
input bool            InpPakaiATR      = false;      // Aktifkan jarak otomatis ATR (false = pakai pip)
input ENUM_TIMEFRAMES InpATRTimeframe  = PERIOD_M1;  // Timeframe ATR
input int             InpATRPeriode    = 14;         // Periode ATR (jumlah candle)
input double          InpATRKaliPending= 1.0;        // Jarak Buy Stop / Sell Stop = ATR x ini
input double          InpATRKaliSL     = 1.0;        // Jarak SL & trailing = ATR x ini
input double          InpATRKaliStep   = 0.3;        // Minimal pergeseran SL = ATR x ini
input bool            InpFilterSepi    = false;      // Jangan pasang pending saat pasar sepi
input double          InpATRMinPip     = 50.0;       // Pasar dianggap sepi jika ATR di bawah ini (pip)

input group "=== Lot Bertingkat ==="
input bool   InpLotBertingkat = false;    // Aktifkan lot naik saat equity berlipat
input double InpModalAcuan    = 0.0;      // Modal acuan (0 = equity saat EA pertama kali dipasang)
input double InpKaliEquity    = 10.0;     // Setiap equity naik ... kali lipat
input double InpKaliLot       = 2.0;      // ... lot dikali ini
input bool   InpLotBolehTurun = true;     // Lot ikut turun jika equity turun lagi

input group "=== Break Even (BEP) ==="
input bool   InpBEP          = false;     // Aktifkan SL ke harga buka saat profit
input double InpBEPOffsetPip = 0.0;       // Tambahan di atas harga buka (pip), misal untuk tutup komisi

input group "=== Sesi Trading ==="
input bool   InpHanyaSesiUS  = true;      // Hanya pasang pending di sesi US
input int    InpJamMulai     = 15;        // Jam mulai sesi (jam SERVER broker, 0-23)
input int    InpJamSelesai   = 24;        // Jam selesai sesi (jam SERVER broker, 1-24)

CTrade   trade;
datetime waktuMulai;
double   pip;
datetime waktuLogTerakhir = 0;
int      pesanHariIni = 0;    // jumlah permintaan ke server hari ini
int      pesanTotal   = 0;    // jumlah permintaan sejak EA start
int      pesanMaks    = 0;    // jumlah harian tertinggi
datetime hariAktif    = 0;
bool     lisensiOK     = false;
double   modalAcuan    = 0;   // dasar perhitungan lot bertingkat
int      levelLot      = 0;   // 0 = lot dasar, 1 = x2, 2 = x4, dst
string   gvModal, gvLevel;
int      atrHandle = INVALID_HANDLE;    // penyimpanan agar tidak reset saat EA/MT5 dibuka ulang
datetime lisensiSampai = 0;   // 0 = selamanya

//+------------------------------------------------------------------+
//| LISENSI                                                          |
//| Format key: TTTTBBHH-XXXXXXXXXXXXXXXX                            |
//|   TTTTBBHH = tanggal berakhir (00000000 = selamanya)             |
//|   XXXX...  = 16 karakter dari SHA-256(rahasia|akun|tanggal)       |
//+------------------------------------------------------------------+
string HashLisensi(string teks)
{
   uchar data[], kunci[], hasil[];
   StringToCharArray(teks, data, 0, StringLen(teks), CP_UTF8);
   if(CryptEncode(CRYPT_HASH_SHA256, data, kunci, hasil) <= 0) return "";
   string hex = "";
   for(int i = 0; i < 8; i++) hex += StringFormat("%02X", hasil[i]);
   return hex;
}

bool CekLisensi()
{
   if(MQLInfoInteger(MQL_TESTER)) { lisensiOK = true; return true; }   // backtest bebas

   string key = InpLisensi;
   StringTrimLeft(key);
   StringTrimRight(key);
   StringToUpper(key);

   string bagian[];
   if(StringSplit(key, '-', bagian) != 2 || StringLen(bagian[0]) != 8 || StringLen(bagian[1]) != 16)
   {
      Alert("License key kosong atau formatnya salah. Hubungi penjual.");
      return false;
   }

   string akun  = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   string harus = HashLisensi(LISENSI_RAHASIA + "|" + akun + "|" + bagian[0]);
   if(harus == "" || harus != bagian[1])
   {
      Alert("License key tidak berlaku untuk akun ", akun, ". Hubungi penjual.");
      return false;
   }

   lisensiSampai = 0;
   if(bagian[0] != "00000000")
   {
      string tgl = StringSubstr(bagian[0], 0, 4) + "." + StringSubstr(bagian[0], 4, 2) + "." +
                   StringSubstr(bagian[0], 6, 2) + " 23:59:59";
      lisensiSampai = StringToTime(tgl);
      if(TimeCurrent() > lisensiSampai)
      {
         Alert("Masa lisensi sudah habis (", TimeToString(lisensiSampai, TIME_DATE), "). Hubungi penjual.");
         return false;
      }
   }

   lisensiOK = true;
   Print("Lisensi valid untuk akun ", akun,
         (lisensiSampai == 0 ? " (tanpa batas waktu)" : " sampai " + TimeToString(lisensiSampai, TIME_DATE)));
   return true;
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpUkuranPip > 0)
      pip = InpUkuranPip;
   else
      pip = (_Digits == 3 || _Digits == 5) ? _Point * 10 : _Point;

   // Cek lisensi. Kalau MT5 baru dibuka dan akun belum login, cek ditunda ke OnTick.
   if(MQLInfoInteger(MQL_TESTER) || AccountInfoInteger(ACCOUNT_LOGIN) != 0)
      if(!CekLisensi()) return(INIT_FAILED);

   trade.SetExpertMagicNumber(InpMagic);
   waktuMulai = TimeCurrent();

   Print("=== EA_StopReverse versi 2.40 ===");
   Print("Simbol: ", _Symbol, " | Digits: ", _Digits, " | 1 pip = ", pip,
         " | Tick size: ", SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE),
         " | Stop Level: ", SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
         " | Freeze Level: ", SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL));

   if(InpHanyaSesiUS)
      Print("Mode sesi US aktif: pending baru hanya dipasang jam ", InpJamMulai,
            ":00 - ", InpJamSelesai, ":00 (jam server)");

   if(JarakMinimal() > InpSLPip * pip)
      Print("PERINGATAN: jarak SL lebih kecil dari jarak minimal broker. EA memakai jarak minimal broker.");

   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("PERINGATAN: akun bukan tipe Hedging.");

   // Lot bertingkat: tentukan modal acuan
   bool tester = (bool)MQLInfoInteger(MQL_TESTER);
   gvModal = "SR_MODAL_" + IntegerToString((long)InpMagic) + "_" + _Symbol;
   gvLevel = "SR_LEVEL_" + IntegerToString((long)InpMagic) + "_" + _Symbol;
   if(InpModalAcuan > 0)
      modalAcuan = InpModalAcuan;
   else if(!tester && GlobalVariableCheck(gvModal))
      modalAcuan = GlobalVariableGet(gvModal);
   else
   {
      modalAcuan = AccountInfoDouble(ACCOUNT_EQUITY);
      if(!tester) GlobalVariableSet(gvModal, modalAcuan);
   }
   levelLot = 0;
   if(!tester && GlobalVariableCheck(gvLevel)) levelLot = (int)GlobalVariableGet(gvLevel);

   if(InpPakaiATR || InpFilterSepi)
   {
      atrHandle = iATR(_Symbol, InpATRTimeframe, InpATRPeriode);
      if(atrHandle == INVALID_HANDLE)
         Print("PERINGATAN: indikator ATR gagal dibuat. EA memakai jarak pip.");
      else
         Print("ATR aktif: ", EnumToString(InpATRTimeframe), " periode ", InpATRPeriode,
               (InpPakaiATR ? " | jarak otomatis ON" : ""),
               (InpFilterSepi ? " | filter sepi ON (min " + DoubleToString(InpATRMinPip, 1) + " pip)" : ""));
   }

   if(InpLotBertingkat)
      Print("Lot bertingkat aktif. Modal acuan: ", DoubleToString(modalAcuan, 2),
            " | lot dasar ", InpLot, " x", InpKaliLot, " setiap equity x", InpKaliEquity);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(pesanHariIni > pesanMaks) pesanMaks = pesanHariIni;
   Print("RINGKASAN PESAN: hari terakhir = ", pesanHariIni,
         " | tertinggi per hari = ", pesanMaks, " | total = ", pesanTotal);
   Comment("");
}

//+------------------------------------------------------------------+
//| Hitung setiap permintaan yang dikirim EA ke server               |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_REQUEST) return;
   if(request.magic != InpMagic && request.magic != 0) return;

   datetime hari = TimeCurrent() - (TimeCurrent() % 86400);
   if(hari != hariAktif)
   {
      if(hariAktif != 0)
      {
         Print("PESAN KE SERVER tanggal ", TimeToString(hariAktif, TIME_DATE), ": ", pesanHariIni);
         if(pesanHariIni > pesanMaks) pesanMaks = pesanHariIni;
      }
      hariAktif    = hari;
      pesanHariIni = 0;
   }
   pesanHariIni++;
   pesanTotal++;
}

//+------------------------------------------------------------------+
double Norm(double harga)
{
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0) tick = _Point;
   return NormalizeDouble(MathRound(harga / tick) * tick, _Digits);
}

//+------------------------------------------------------------------+
double JarakMinimal()
{
   long stopLv   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLv = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)(MathMax(stopLv, freezeLv) + 1) * _Point;
}

//+------------------------------------------------------------------+
void LogGagal(string aksi)
{
   if(TimeCurrent() - waktuLogTerakhir < 10) return;
   waktuLogTerakhir = TimeCurrent();
   Print("GAGAL ", aksi, " | kode ", trade.ResultRetcode(), ": ",
         trade.ResultRetcodeDescription(),
         " | Bid ", DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_BID), _Digits),
         " | Ask ", DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_ASK), _Digits));
}

//+------------------------------------------------------------------+
//| Apakah sekarang di dalam jam sesi yang diizinkan                 |
//+------------------------------------------------------------------+
bool DalamSesi()
{
   if(!InpHanyaSesiUS) return true;

   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   int jam = t.hour;

   if(InpJamMulai < InpJamSelesai)
      return (jam >= InpJamMulai && jam < InpJamSelesai);
   return (jam >= InpJamMulai || jam < InpJamSelesai);   // sesi melewati tengah malam
}

//+------------------------------------------------------------------+
bool AmbilPosisi(ulong &ticket, long &tipe, double &hargaBuka, double &sl)
{
   bool ada     = false;
   long terbaru = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;

      long wkt = PositionGetInteger(POSITION_TIME_MSC);
      if(!ada || wkt > terbaru)
      {
         ada       = true;
         terbaru   = wkt;
         ticket    = t;
         tipe      = PositionGetInteger(POSITION_TYPE);
         hargaBuka = PositionGetDouble(POSITION_PRICE_OPEN);
         sl        = PositionGetDouble(POSITION_SL);
      }
   }
   return ada;
}

//+------------------------------------------------------------------+
int HitungPending()
{
   int jumlah = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)InpMagic) continue;
      jumlah++;
   }
   return jumlah;
}

//+------------------------------------------------------------------+
void HapusSemuaPending()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)InpMagic) continue;
      if(!trade.OrderDelete(t)) LogGagal("hapus pending");
   }
}

//+------------------------------------------------------------------+
//| Bulatkan lot sesuai aturan broker (step, minimal, maksimal)      |
//+------------------------------------------------------------------+
double NormLot(double lot)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   int digit = (int)MathMax(0, -MathFloor(MathLog10(step) + 1e-9));
   lot = MathFloor(lot / step + 1e-9) * step;
   lot = MathMax(mn, MathMin(mx, lot));
   return NormalizeDouble(lot, digit);
}

//+------------------------------------------------------------------+
//| Hitung lot: dasar, atau bertingkat mengikuti equity              |
//| Contoh (acuan 100, x10 equity, x2 lot, dasar 0.01):              |
//|   equity 100-999 -> 0.01 | 1.000-9.999 -> 0.02 | 10.000+ -> 0.04 |
//+------------------------------------------------------------------+
double HitungLot()
{
   if(!InpLotBertingkat || modalAcuan <= 0 || InpKaliEquity <= 1)
      return NormLot(InpLot);

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   int lv = 0;
   if(eq >= modalAcuan)
      lv = (int)MathFloor(MathLog(eq / modalAcuan) / MathLog(InpKaliEquity) + 1e-9);
   if(!InpLotBolehTurun && lv < levelLot) lv = levelLot;

   if(lv != levelLot)
   {
      Print("Lot bertingkat: level ", levelLot, " -> ", lv,
            " | equity ", DoubleToString(eq, 2),
            " | lot ", DoubleToString(NormLot(InpLot * MathPow(InpKaliLot, lv)), 2));
      levelLot = lv;
      if(!MQLInfoInteger(MQL_TESTER)) GlobalVariableSet(gvLevel, lv);
   }
   return NormLot(InpLot * MathPow(InpKaliLot, lv));
}

//+------------------------------------------------------------------+
//| ATR dari candle terakhir yang sudah selesai (0 jika belum siap)  |
//+------------------------------------------------------------------+
double AmbilATR()
{
   if(atrHandle == INVALID_HANDLE) return 0;
   double buf[];
   if(CopyBuffer(atrHandle, 0, 1, 1, buf) != 1) return 0;
   return buf[0];
}

//+------------------------------------------------------------------+
//| Jarak dalam satuan harga: dari ATR (jika aktif) atau dari pip    |
//+------------------------------------------------------------------+
double JarakPending()
{
   double atr = InpPakaiATR ? AmbilATR() : 0;
   double j   = (atr > 0) ? atr * InpATRKaliPending : InpJarakAwalPip * pip;
   return MathMax(j, JarakMinimal());
}

double JarakSL()
{
   double atr = InpPakaiATR ? AmbilATR() : 0;
   double j   = (atr > 0) ? atr * InpATRKaliSL : InpSLPip * pip;
   return MathMax(j, JarakMinimal());
}

double StepTrail()
{
   double atr = InpPakaiATR ? AmbilATR() : 0;
   return (atr > 0) ? atr * InpATRKaliStep : InpTrailStepPip * pip;
}

bool PasarSepi()
{
   if(!InpFilterSepi) return false;
   double atr = AmbilATR();
   if(atr <= 0) return false;              // data belum siap -> jangan blokir
   return (atr < InpATRMinPip * pip);
}

//+------------------------------------------------------------------+
void PasangPendingPasangan()
{
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double jarak = JarakPending();
   double slJ   = JarakSL();

   double hBuy  = Norm(ask + jarak);
   double hSell = Norm(bid - jarak);
   double lot   = HitungLot();

   if(!trade.BuyStop(lot, hBuy, _Symbol, Norm(hBuy - slJ), 0, ORDER_TIME_GTC, 0, "Buy Stop"))
      LogGagal("pasang Buy Stop");
   if(!trade.SellStop(lot, hSell, _Symbol, Norm(hSell + slJ), 0, ORDER_TIME_GTC, 0, "Sell Stop"))
      LogGagal("pasang Sell Stop");
}

//+------------------------------------------------------------------+
//| Trailing SL: hanya bergerak searah profit                        |
//| + BEP: begitu profit, SL langsung ke harga buka (jika diizinkan  |
//|   jarak minimal broker; kalau belum, tunggu sampai memenuhi)     |
//+------------------------------------------------------------------+
void TrailingSL(ulong ticket, long tipe, double hargaBuka, double sl)
{
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minD   = JarakMinimal();
   double jarak  = JarakSL();
   double step   = StepTrail();
   double offset = InpBEPOffsetPip * pip;
   double target, bep;
   bool   geser, keBEP;

   if(tipe == POSITION_TYPE_BUY)
   {
      bep    = Norm(hargaBuka + offset);
      target = Norm(bid - jarak);
      if(sl == 0) target = MathMax(target, Norm(hargaBuka - jarak));

      // BEP: hanya jika harga sudah cukup jauh dari BEP (aturan jarak minimal)
      if(InpBEP && bid - minD >= bep && target < bep) target = bep;

      if(target > bid - minD) target = Norm(bid - minD);

      keBEP = InpBEP && sl < bep - _Point / 2 && target >= bep - _Point / 2;
      geser = (sl == 0) || keBEP ||
              (target > sl + _Point / 2 && target - sl >= step - _Point / 2);
   }
   else
   {
      bep    = Norm(hargaBuka - offset);
      target = Norm(ask + jarak);
      if(sl == 0) target = MathMin(target, Norm(hargaBuka + jarak));

      if(InpBEP && ask + minD <= bep && target > bep) target = bep;

      if(target < ask + minD) target = Norm(ask + minD);

      keBEP = InpBEP && (sl == 0 || sl > bep + _Point / 2) && target <= bep + _Point / 2;
      geser = (sl == 0) || keBEP ||
              (target < sl - _Point / 2 && sl - target >= step - _Point / 2);
   }

   if(geser)
   {
      if(trade.PositionModify(ticket, target, 0)) sl = target;
      else LogGagal(keBEP ? "geser SL ke BEP" : "geser SL");
   }

   bool sudahBEP = (tipe == POSITION_TYPE_BUY) ? (sl >= bep - _Point / 2) : (sl > 0 && sl <= bep + _Point / 2);

   Comment("Posisi: ", (tipe == POSITION_TYPE_BUY ? "BUY" : "SELL"),
           "\nSL: ", DoubleToString(sl, _Digits),
           (InpBEP ? (sudahBEP ? "  (sudah BEP)" : "  (belum BEP)") : ""),
           "\nSesi: ", (DalamSesi() ? "aktif" : "di luar sesi (tidak pasang pending baru)"),
           "\nPesan ke server hari ini: ", pesanHariIni);
}

//+------------------------------------------------------------------+
void OnTick()
{
   // Lisensi belum dicek (akun belum login saat EA dipasang)
   if(!lisensiOK)
   {
      if(AccountInfoInteger(ACCOUNT_LOGIN) == 0) return;
      if(!CekLisensi()) { ExpertRemove(); return; }
   }

   // Masa lisensi habis saat EA berjalan: posisi terbuka tetap dijaga SL-nya,
   // tapi tidak ada order baru
   bool lisensiHabis = (lisensiSampai > 0 && TimeCurrent() > lisensiSampai);

   int sisa = (int)(waktuMulai + InpDelayMenit * 60 - TimeCurrent());
   if(sisa > 0)
   {
      Comment("Menunggu ", sisa, " detik...");
      return;
   }

   ulong  posTicket = 0;
   long   posTipe   = 0;
   double posBuka   = 0, posSL = 0;

   // Ada posisi: hapus pending tersisa, hanya SL yang bergerak
   if(AmbilPosisi(posTicket, posTipe, posBuka, posSL))
   {
      if(HitungPending() > 0) HapusSemuaPending();
      TrailingSL(posTicket, posTipe, posBuka, posSL);
      return;
   }

   if(lisensiHabis)
   {
      if(HitungPending() > 0) HapusSemuaPending();
      Comment("Masa lisensi sudah habis. EA tidak memasang order baru. Hubungi penjual.");
      return;
   }

   // Tidak ada posisi, di luar sesi: jangan pasang, hapus pending yang menunggu
   if(!DalamSesi())
   {
      if(HitungPending() > 0) HapusSemuaPending();
      Comment("Di luar sesi. Menunggu jam ", InpJamMulai, ":00 (server)",
              "\nPesan ke server hari ini: ", pesanHariIni);
      return;
   }

   // Tidak ada posisi, pasar sepi: jangan pasang, hapus pending yang menunggu
   if(PasarSepi())
   {
      if(HitungPending() > 0) HapusSemuaPending();
      Comment("Pasar sepi (ATR ", DoubleToString(AmbilATR() / pip, 1), " pip < ",
              DoubleToString(InpATRMinPip, 1), " pip). Menunggu...",
              "\nPesan ke server hari ini: ", pesanHariIni);
      return;
   }

   // Tidak ada posisi, dalam sesi: pastikan ada sepasang Buy Stop & Sell Stop
   int n = HitungPending();
   if(n == 0)
      PasangPendingPasangan();
   else if(n != 2)
      HapusSemuaPending();   // pasangan tidak lengkap -> hapus, tick berikutnya pasang ulang

   Comment("Menunggu Buy Stop / Sell Stop tersentuh...",
           (InpPakaiATR || InpFilterSepi ? "\nATR: " + DoubleToString(AmbilATR() / pip, 1) + " pip" : ""),
           "\nLot: ", DoubleToString(HitungLot(), 2),
           (InpLotBertingkat ? " (level " + IntegerToString(levelLot) + ")" : ""),
           "\nPesan ke server hari ini: ", pesanHariIni);
}
//+------------------------------------------------------------------+
