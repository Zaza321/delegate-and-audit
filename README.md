# delegate-and-audit

Claude Code üzerinden açık istekle Codex, Grok, Gemini (`agy`) veya DeepSeek'e proje içi görev devretmek için Windows odaklı bir skill. Tek işçi devri, **ayrı işleri aynı proje kökünde** iki ya da üç işçiye paralel verme ve **aynı incelemeyi ayrı proje kopyalarında** iki ya da üç sağlayıcıyla çapraz denetleme yolları vardır.

**Kendiliğinden model çağırmaz.** Kullanıcı açıkça devir veya çapraz denetim istemelidir. Dış modellerin kullanımı kendi hesap/API koşullarınıza tabidir; `--dry-run` yalnız yerel hazırlığı kontrol eder.

## Tek promptla kurulum

Aşağıdaki metni Windows'taki Claude Code oturumuna tek mesaj olarak yapıştırın.

```text
Windows bilgisayarıma https://github.com/Zaza321/delegate-and-audit deposundaki Claude Code skillini kur. Hedef klasör $HOME\.claude\skills\delegate-and-audit olsun. Depoya erişim hatası olursa durumu bildir; kimlik bilgilerini sohbete isteme.

Önce Git, PowerShell 7 (pwsh), Python 3.10+ ve depo erişimini kontrol et. Depoyu hedefin yanında geçici bir klasöre klonla; SKILL.md, scripts/ ve references/ dosyalarının yerinde olduğunu doğrula. Mevcut kurulum varsa henüz değiştirme.

Geçici klonun kökünde model çağırmadan `python tests/test_release.py` çalıştır. Node.js varsa ayrıca `pwsh -NoProfile -File tests/test_delegate.ps1` çalıştır; Node.js yoksa ikinci testi atlayıp nedenini yaz. Kullanacağım sağlayıcıların CLI/oturum durumunu kontrol et ve eksikleri listele; canlı model çağrısı yapma. DeepSeek API anahtarını sohbete, komut satırına veya repo dosyasına yazma; gerekiyorsa etkileşimli Set-DeepSeekKey.ps1 yolunu anlat.

Testler ve temel dosya kontrolleri başarılıysa geçici klonu hedefe kur. Hedef klasör zaten varsa önce onu $HOME\.claude\skill-backups altında zaman damgalı ayrı bir klasöre taşı; hiçbir dosyayı silme veya üzerine yazma. Kurulum başarısızsa eski kurulumu yerinde bırak ya da geri getir. Sonunda kurulan mutlak yolu, varsa yedek yolunu, Git commit'ini, test sonuçlarını, eksik gereksinimleri ve Claude Code oturumunu yeniden açmam gerekip gerekmediğini kısa bir özetle bildir.
```

## Gereksinimler

- Windows 10/11, PowerShell 7 (`pwsh`), Python 3.10+ ve Git.
- Kullanacağınız sağlayıcıların yerel CLI'ları ve oturumları: `codex`, `grok`, `agy`. Yalnız DeepSeek için CLI gerekmez; API anahtarı gerekir. En az kullanacağınız sağlayıcıyı kurun.
- Bu sürüm Windows süreç yönetimini ve DeepSeek anahtarının Windows kullanıcı şifreli deposunu kullanır. Başka işletim sistemlerinde destek taahhüdü yoktur.

## Kurulum

Depoyu `~/.claude/skills/delegate-and-audit` konumuna klonlayın veya içeriğini bu klasöre kopyalayın. Yolları kendi makinenize göre değiştirin:

```powershell
New-Item -ItemType Directory -Force (Join-Path $HOME '.claude\skills') | Out-Null
git clone https://github.com/Zaza321/delegate-and-audit.git (Join-Path $HOME '.claude\skills\delegate-and-audit')
```

Bu klasörde `SKILL.md` ve `scripts/` birlikte olmalıdır. Skill başka bir dizine kurulursa aşağıdaki betik yollarını yeni konuma uyarlayın. CLI'larda oturum açmayı kendi sağlayıcılarının yönergeleriyle tamamlayın. DeepSeek kullanacaksanız `DEEPSEEK_API_KEY` ortam değişkenini ayarlayın **veya** `pwsh -File scripts/Set-DeepSeekKey.ps1` komutuyla anahtarı etkileşimli girin; anahtarı repo, görev notu veya komut satırına koymayın.

## Hızlı kullanım

Claude'a örneğin “Bu projede şu görevi Codex Sol'a ver, sonucunu ve değişikliklerini denetle” deyin. Skill gerçek `taskRoot` yolunu seçer. Elle tek işçi çağrısı:

```powershell
$skill = Join-Path $HOME '.claude\skills\delegate-and-audit'
$root = 'C:\projeler\ornek'
$task = 'C:\gorevler\ornek-gorev.txt'
& (Join-Path $skill 'scripts\Invoke-Delegate.ps1') -Provider codex -TaskRoot $root -TaskFile $task -DryRun
# Canlı çağrı yalnız kullanıcı açıkça istediğinde: aynı komutta -DryRun bayrağını çıkarın.
```

Varsayılanlar: Codex `gpt-6-sol/high`, Grok `grok-4.7/xhigh`, Gemini `gemini-3.8-flash-high`, DeepSeek `deepseek-v4-pro/high`. Hesabınızın model erişimi değişebilir; `-Model` ve ilgili efor bayrağıyla açık seçim yapabilirsiniz. Grok süre sınırı varsayılan 45 dakika, diğerleri 15 dakikadır; `-TimeoutSeconds` değiştirir.

Ayrı işler için `Invoke-ParallelTasks.py`: iki veya üç işçi planı (`workers`) ve işçi başına farklı `task_file` verin. İşçiler aynı `taskRoot` üzerinde çalışır; yazma işleri için çakışmayan dosya sahipliği seçin. Aynı görevin bağımsız incelemesi için `Invoke-CrossReview.py`: iki veya üç **farklı** sağlayıcı, her birine ayrı proje kopyası. Örnek komutlar ve bütün seçenekler [SKILL.md](SKILL.md) içindedir. Bu iki yol birbirinin yerine geçmez.

## Sonuç ve sınırlar

Her koşunun `status.json` ve `final.txt` dosyasını okuyun. Okuma sınaması seçilen dosyadaki satırın tam eşleşmesini ölçer; bütün mimarinin anlaşıldığını kanıtlamaz. `result_contract` işçi beyanını denetler; kod ve test iddialarını ana ajan ayrıca doğrular. `--dry-run` canlı model sonucu üretmez. Çapraz denetim bulguları otomatik doğrulanmış sayılmaz.

DeepSeek `context` kipinde uygun UTF-8 proje dosyaları istekle birlikte gönderilir. Büyük projeler için `read-tools` yalnız okuma araçlarını açar. Hassas ve Git tarafından yok sayılan dosyalar varsayılan dışındadır; `-DeepSeekIncludeSensitive` veya `-DeepSeekIncludeIgnored` seçimi dış aktarım kapsamını değiştirir. Sağlayıcıya gitmesini istemediğiniz verileri görevden önce gözden geçirin. `agy` başsız kipinde güçlü araç izinleriyle çalışabilir; yazma ve dış eylemleri görev tanımında sınırlandırın. Ayrıntılar [sağlayıcı notlarında](references/provider-notes.md).

## Yerel doğrulama

Model çağırmayan testler:

```powershell
python tests/test_release.py
pwsh -NoProfile -File tests/test_delegate.ps1
```

İkinci test Node.js de gerektirir; sahte Grok işçisiyle süreç, erişim kanıtı ve Git karşılaştırması yollarını dener. Gerçek sağlayıcı hesabı gerektirmez. Canlı smoke testleri ağ, hesap ve ücretli kullanım gerektirebilir; ayrı ve açık istekle yapılmalıdır.

## Lisans

Bu depoya henüz açık kaynak lisansı eklenmedi. Lisans koşulları ayrıca belirlenecektir.
