# delegate-and-audit

Claude Code üzerinden açık istekle Codex, Grok, Gemini (`agy`) veya DeepSeek'e proje içi görev devretmek için Windows odaklı bir skill. Tek işçi devri, **ayrı işleri aynı proje kökünde** iki ya da üç işçiye paralel verme ve **aynı incelemeyi ayrı proje kopyalarında** iki ya da üç sağlayıcıyla çapraz denetleme yolları vardır.

**Kendiliğinden model çağırmaz.** Kullanıcı açıkça devir veya çapraz denetim istemelidir. Dış modellerin kullanımı kendi hesap/API koşullarınıza tabidir; `--dry-run` yalnız yerel hazırlığı kontrol eder.

## Gereksinimler

- Windows 10/11, PowerShell 7 (`pwsh`), Python 3.10+ ve Git.
- Kullanacağınız sağlayıcıların yerel CLI'ları ve oturumları: `codex`, `grok`, `agy`. Yalnız DeepSeek için CLI gerekmez; API anahtarı gerekir. En az kullanacağınız sağlayıcıyı kurun.
- Bu sürüm Windows süreç yönetimini ve DeepSeek anahtarının Windows kullanıcı şifreli deposunu kullanır. Başka işletim sistemlerinde destek taahhüdü yoktur.

## Kurulum

Depoyu `~/.claude/skills/delegate-and-audit` konumuna klonlayın veya içeriğini bu klasöre kopyalayın. Yolları kendi makinenize göre değiştirin:

```powershell
New-Item -ItemType Directory -Force (Join-Path $HOME '.claude\skills') | Out-Null
git clone <repository-url> (Join-Path $HOME '.claude\skills\delegate-and-audit')
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

Bu depoya henüz açık kaynak lisansı eklenmedi. Herkese açık paylaşmadan önce telif sahibi ve lisans koşulları ayrıca belirlenecektir.
