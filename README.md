# Deniz PC Monitör

Şirket bilgisayarlarının **açılma/kapanma zamanlarını**, **açılan uygulamaları** ve
**uygulama kullanım sürelerini** toplayıp `crm.denizbelge.com` → **PC Logları** sayfasına gönderen
hafif, **şeffaf** bir aktivite kaydı ajanı.

> ⚠️ **Gizli bir araç değildir.** Görev çubuğunda ikon gösterir ve açılışta bir bilgilendirme
> balonu çıkarır. Yalnızca **şirkete ait** cihazlarda ve o cihazı kullanan **personelin bilgisi
> dahilinde** kullanılmalıdır. Kişinin haberi olmadan gizli izleme amacıyla kullanılamaz.

## Ne toplar?
- Açılma / kapanma / uyku–uyanma zamanları (Windows olay günlüğünden)
- Hangi uygulamalar açıldı
- Her uygulamada aktif olarak ne kadar süre kalındı (boşta geçen süre sayılmaz)

Ekran görüntüsü, tuş vuruşu, pencere içeriği **toplanmaz**.

## Kurulum (hedef bilgisayarda, yönetici PowerShell)
```powershell
$env:PCM_TOKEN='BURAYA_TOKEN'
irm https://raw.githubusercontent.com/byogungan/deniz-pc-monitor/main/install.ps1 | iex
```
Açılışta otomatik başlar, 10 dakikada bir CRM'e gönderir.

## Elle çalıştırma (kurmadan test)
```powershell
$env:PCM_TOKEN='BURAYA_TOKEN'
powershell -ExecutionPolicy Bypass -File .\pc-monitor.ps1
```

## Kaldırma
```powershell
irm https://raw.githubusercontent.com/byogungan/deniz-pc-monitor/main/uninstall.ps1 | iex
```

## Gizlilik / hukuk
Çalışanların izlendiğini bilmesi gerekir. Kurmadan önce cihaz kullanım politikanıza
"bu cihaz izlenebilir" maddesini ekleyin ve personeli bilgilendirin.
