// =====================================================================
// Supabase Edge Function: kelola-akun
// Dipanggil dari Portal Office (menu Karyawan) untuk membuat, mengubah,
// atau mencabut akun login terapis.
//
// Simpan sebagai: supabase/functions/kelola-akun/index.ts
// Deploy        : supabase functions deploy kelola-akun
// Secret        : SERVICE_ROLE_KEY otomatis tersedia sebagai env di Edge Function
// =====================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const balas = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const URL = Deno.env.get("SUPABASE_URL")!;
  const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;

  // 1. Pastikan pemanggil sudah login dan berhak (owner/admin/manajer)
  const token = req.headers.get("Authorization")?.replace("Bearer ", "");
  if (!token) return balas({ error: "Belum masuk." }, 401);

  const asUser = createClient(URL, ANON, { global: { headers: { Authorization: `Bearer ${token}` } } });
  const { data: { user } } = await asUser.auth.getUser();
  if (!user) return balas({ error: "Sesi tidak valid." }, 401);

  const admin = createClient(URL, SERVICE);
  const { data: pemanggil } = await admin
    .from("karyawan").select("role, status").eq("user_id", user.id).single();

  if (!pemanggil || pemanggil.status !== "aktif" || !["owner", "admin", "manajer"].includes(pemanggil.role))
    return balas({ error: "Hanya owner, admin, atau manajer yang boleh mengelola akun." }, 403);

  // 2. Jalankan aksi
  const { aksi, karyawan_id, email, password, user_id } = await req.json();

  try {
    if (aksi === "buat") {
      if (!email || !password || password.length < 6)
        return balas({ error: "Email wajib diisi dan kata sandi minimal 6 karakter." }, 400);

      const { data, error } = await admin.auth.admin.createUser({
        email, password, email_confirm: true,
        user_metadata: { karyawan_id },
      });
      if (error) return balas({ error: error.message }, 400);

      await admin.from("karyawan").update({ user_id: data.user.id, email }).eq("id", karyawan_id);
      return balas({ user_id: data.user.id, email });
    }

    if (aksi === "ubah") {
      if (!user_id) return balas({ error: "Akun belum ada. Buat akun terlebih dahulu." }, 400);
      const patch: Record<string, string> = {};
      if (email) patch.email = email;
      if (password) {
        if (password.length < 6) return balas({ error: "Kata sandi minimal 6 karakter." }, 400);
        patch.password = password;
      }
      const { error } = await admin.auth.admin.updateUserById(user_id, patch);
      if (error) return balas({ error: error.message }, 400);

      if (email) await admin.from("karyawan").update({ email }).eq("id", karyawan_id);
      return balas({ user_id, email });
    }

    if (aksi === "hapus") {
      if (!user_id) return balas({ error: "Akun tidak ditemukan." }, 400);
      const { error } = await admin.auth.admin.deleteUser(user_id);
      if (error) return balas({ error: error.message }, 400);
      await admin.from("karyawan").update({ user_id: null }).eq("user_id", user_id);
      return balas({ ok: true });
    }

    return balas({ error: "Aksi tidak dikenal." }, 400);
  } catch (e) {
    return balas({ error: String(e) }, 500);
  }
});
