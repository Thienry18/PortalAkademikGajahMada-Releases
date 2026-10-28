# Portal Akademik Gajah Mada

Paket pengguna untuk menjalankan frontend, backend, MySQL, dan gateway di komputer sendiri. Image aplikasi publik tersedia di Docker Hub:

- [thien18/portal-akademik-frontend](https://hub.docker.com/r/thien18/portal-akademik-frontend)
- [thien18/portal-akademik-backend](https://hub.docker.com/r/thien18/portal-akademik-backend)
- [thien18/portal-akademik-gateway](https://hub.docker.com/r/thien18/portal-akademik-gateway)

## Instalasi Windows

1. Pasang dan aktifkan Docker Desktop dalam mode Linux containers. Rilis ini untuk linux/amd64 (Windows x64 dengan Docker Desktop).
2. Unduh [paket ZIP](https://github.com/Thienry18/PortalAkademikGajahMada-Releases/archive/refs/heads/main.zip) dan ekstrak ke folder biasa.
3. Buka PowerShell di folder hasil ekstraksi, lalu jalankan:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Portal.ps1
```

Installer membuat secret lokal acak, mengunduh empat image yang ditunjuk rilis stabil, menjalankan aplikasi, dan mendaftarkan task Windows untuk memeriksa pembaruan setiap lima menit ketika pengguna sedang login. Tidak perlu akun GitHub, Docker Hub, akses repo privat, Node.js, atau runner GitHub di komputer pengguna. Task hanya berjalan saat komputer aktif dan Docker Desktop tersedia; jika Docker belum siap, pemeriksaan berikutnya dapat mencoba lagi.

Jika port 8080 sudah dipakai:

```powershell
.\Install-Portal.ps1 -Port 8081
```

Alamat aplikasi: http://127.0.0.1:8080 (atau port yang dipilih). Folder instalasi default: `%LOCALAPPDATA%\PortalAkademik`. Jika Windows menolak pendaftaran task, buka PowerShell sebagai administrator dengan akun Windows yang sama lalu jalankan installer lagi. Aplikasi tidak dilaporkan memiliki pembaruan otomatis sampai pendaftaran task berhasil.

Untuk pemasangan tanpa task terjadwal:

```powershell
.\Install-Portal.ps1 -NoAutoUpdate
```

## Cara pembaruan bekerja

CI membangun dan menguji image. Setelah deployment uji di komputer penerbit berhasil, job publikasi mengunggah image tersebut ke Docker Hub, memverifikasi akses pull anonim, lalu mempublikasikan satu manifest `stable.json`. Semua image aplikasi dipatok ke digest SHA256, sehingga frontend/backend/gateway berasal dari satu rilis yang sama. Pengguna mengikuti kanal stabil, bukan tag latest yang diperbarui secara terpisah.

Updater mengambil seluruh image aplikasi sebelum mengganti container, memeriksa empat layanan healthy, tampilan, koneksi database, dan identitas release backend. Jika startup atau verifikasi gagal, updater mencoba memulihkan image aplikasi sebelumnya. Rilis yang gagal tidak dicoba setiap lima menit; updater menunggu versi baru. Retry manual untuk versi yang gagal dapat dilakukan dengan `-Force` setelah masalahnya diperbaiki.

Secret `.env`, database, dan uploads tetap milik instalasi masing-masing. Updater tidak menghapus volume, tidak menyamakan database antar pengguna, dan tidak melakukan rollback data. MySQL dipatok pada image instalasi awal dan tidak dinaikkan otomatis. Migrasi aplikasi harus aditif serta kompatibel dengan versi sebelumnya. Rilis yang membutuhkan perubahan topologi Compose atau format updater memerlukan installer baru, bukan pembaruan diam-diam.

## Akun demo lokal

| Peran | Username | Password |
| --- | --- | --- |
| Admin | admin_portal | Admin@1234 |
| Guru | guru_budi | Guru@1234 |
| Siswa | siswa_rizky | Siswa@1234 |
| Orang tua | ortu_ahmad | Ortu@1234 |

Aplikasi hanya membuka port pada loopback komputer. Akun di atas adalah akun demo. Jangan mengunggah file `.env`, folder instalasi, atau database pribadi ke repositori publik.

## Pemeriksaan dan penghentian pembaruan

```powershell
& "$env:LOCALAPPDATA\PortalAkademik\Update-Portal.ps1"
Get-Content "$env:LOCALAPPDATA\PortalAkademik\updater.log" -Tail 20
& "$env:LOCALAPPDATA\PortalAkademik\Uninstall-Portal.ps1"
```

Perintah terakhir menonaktifkan pembaruan otomatis; file instalasi dan data tetap disimpan. Tambahkan `-StopApplication` untuk menghentikan empat container tanpa menghapus volumenya.

Sumber aplikasi: [Frederycho77/PortalAkademikGajahMada](https://github.com/Frederycho77/PortalAkademikGajahMada). Repositori ini hanya berisi installer dan metadata distribusi, sedangkan pengembangan dilakukan pada repo terpisah.
