---
name: delegate-and-audit
description: >
  Kullanıcının açık isteğiyle Claude, Codex, Grok, Gemini (agy) ve DeepSeek arasında
  proje içi iş devri ve gelen sonucu denetleme yöntemi. Başka modele iş verirken aktif proje kökünü
  bağlamak, işçinin dosyaları gerçekten okuduğunu doğrulamak ve rapordaki
  iddiaları bağımsız incelemek için kullan. Bu bir izin sistemi değildir.
---

# İşi devret, geleni denetle

**İş devrini kendiliğinden başlatma.** Kullanıcı açıkça "Codex'e ver",
"Grok'a ver" veya benzeri bir devir istemedikçe hiçbir dış işçi çağırma.
Modeli açıkça söylemişse onu seç; "sen seç" diyerek seçimi açıkça bırakmışsa
işin gerektirdiği araçları ve o anki CLI durumunu ölçüp karar ver. Kod
incelemesi, zor görev veya mevcut skill'in varlığı kendi başına devir isteği
sayılmaz. Codex, Grok ve
`agy` ayrı süreçlerdir; aynı modelin alt ajanı farklı model sayılmaz. Web,
dosya ve terminal yeteneklerini eski rol tablosundan varsayma. Sağlayıcı kurulum ve sınırları için yalnız ilgili bölümü
[sağlayıcı notlarında](references/provider-notes.md) oku; CLI sürüm ve model erişimini
kendi kurulumunda doğrula. DeepSeek API üzerinden çalışır;
varsayılan modda proje dosyaları istek bağlamına eklenir ve dosya düzenlemez.

## 1. Aktif projeyi seç

**Her devir için `taskRoot` açık bir mutlak yol olmalı.** Bu, işçinin açacağı
proje veya monorepo içindeki ilgili alt projedir. `gitRoot` commit/diff
kimliği için ayrı kaydedilir; `taskRoot` otomatik olarak Git köküne
yükseltilmez. Ayrı worktree varsa onun içindeki görev klasörünü kullan.

- Kullanıcı belirli proje yolu verdiyse onu seç. Birden fazla proje açık ve
  hedef belirsizse yanlış klasörde işçi çalıştırma; hedefi netleştir.
- Claude Code v2.1.196+ içinde bu skill Markdown'indeki
  `${CLAUDE_PROJECT_DIR}` aktif proje köküne genişletilir. **Yalnız Claude
  oturumunda** bu değeri başlangıç adayı olarak al; alt proje veya kullanıcının
  açık yol tercihi varsa onu kullan. Grok'un aynı placeholder'ı genişlettiği
  belgelenmediği için Grok oturumunda literal olarak aktarma.
- Shell `Get-Location` veya `pwd`, proje yoluna dair adaydır; önceki `cd`,
  terminalin home dizini veya işçinin kendi scratch workspace'i olabilir.
  Görevin gerçek dosyalarıyla eşleştiğini kontrol et. Skill klasörü ve önceki
  görevdeki depo varsayılan olamaz.

İşçiyi doğrudan CLI ile çağıracaksan aynı mutlak `taskRoot` değerini süreç
çalışma dizini ve Codex `-C`, Grok `--cwd`, `agy --add-dir` ile geçir. `agy`
için `--add-dir` **mutlak** olmalı; yalnız `cd` yeterli değil. `agy --project`
klasör yolu değil proje adı/ID'sidir. Proje dosyalarını açmadan verilen mimari
raporunu kabul etme. DeepSeek bağlamı proje kökünden hazırlanır; bağlama
sığmayan büyük projede çağrı durur ve başarı sayılmaz. Eski `*.bak-*`
yedekleri ve boş dosyalar bağlam paketine alınmaz.

## 2. Windows başlatıcısı

Tekrarlanan CLI çağrıları için bu skill ile gelen
[`scripts/Invoke-Delegate.ps1`](scripts/Invoke-Delegate.ps1) kullan. Başlatıcı
`taskRoot`'u doğrular, `gitRoot`/başlangıç commit'ini ayrı kaydeder, yerel CLI
bayraklarını denetler ve sonucu geçici koşu klasörüne yazar. Proje içindeki
bir metin dosyasından rastgele satır seçer; içeriğini işçiye söylemeden o
satırı okumasını ister. Yalnız seçilen dosya, satır numarası ve tam satır
metni eşleşirse okuma sınaması geçer; başka satır `unverified` olur.
Bu sınama dosya erişimine dair güçlü bir işarettir; native CLI dosya açma
eylemi ayrıca izlenmez ve görevin doğruluğu tek başına kanıtlanmaz.

```powershell
$SkillScript = Join-Path $HOME '.claude\skills\delegate-and-audit\scripts\Invoke-Delegate.ps1'
$TaskRoot = '<aktif projenin gerçek mutlak yolu>'
$TaskFile = '<UTF-8 görev notunun mutlak yolu>'
& $SkillScript -Provider codex -TaskRoot $TaskRoot -TaskFile $TaskFile
```

Buradaki `<...>` örneklerini literal çalıştırma. Claude oturumunda
`$TaskRoot = '${CLAUDE_PROJECT_DIR}'` kullan; Claude bu skill metnindeki
değişkeni gerçek proje yoluna genişletir. Grok oturumunda kendi aktif
projesinin doğrulanmış mutlak yolunu kullan; `${CLAUDE_PROJECT_DIR}`
metnini Grok kabuğuna literal olarak gönderme. `-Provider grok`,
`-Provider agy` veya `-Provider deepseek` aynı
başlatıcıyla çalışır. Kök dizinde uygun metin dosyası yoksa proje içindeki
birini `-ProbeFile` ile ver. `-Model`, `-TimeoutSeconds`, `-RunDirectory` ve
Codex için `-CodexSandbox` isteğe bağlıdır. `-DryRun` model çağırmadan kök,
CLI/API komut hazırlığını kontrol eder; başarı iddiası değildir.

Codex devrinde varsayılan `gpt-6-sol` ve `high`tır; başlatıcı ikisini de
CLI'ya açıkça verir. Kullanıcı Astra veya başka model isterse
`-Model gpt-6-astra` gibi açık seçim kullan; varsayılan modele geri düşme.
Gerekirse Codex eforu `-CodexReasoningEffort` ile ayrıca seçilebilir.

DeepSeek için varsayılan model `deepseek-v4-pro`, erişim `context` ve akıl
yürütme seviyesi `high`tır. API anahtarını `DEEPSEEK_API_KEY` ortam
değişkeninden veya `scripts/Set-DeepSeekKey.ps1` ile Windows kullanıcı
hesabına bağlı şifreli depodan alır; prompt, görev ve sonuç dosyasına
yazmaz. Anahtar ilk kez kurulurken `Set-DeepSeekKey.ps1` çalıştır.
`context`
modunda dosya içeriği modele **sunulur**; modelin dosyayı kendi aracıyla
açtığı iddia edilmez. Başarılı sonuç `verified_project_context` ve
`read_proof_kind: context_supplied` olarak kaydedilir. Büyük projede araçlı
okuma açıkça seçilirse `-DeepSeekAccess read-tools` kullanılabilir; bu mod
yalnız `list_files`, `read_file` ve `search_text` verir. Kullanıcının bu iş
için seçtiği yol `context` modudur.
DeepSeek API'ye yalnız yerel klasör yolunu vermek dosya erişimi sağlamaz.
Çapraz denetim her işçi için ayrı proje kopyası açar; `context` bu kopyanın
uygun dosyalarını gönderir, `read-tools` ise okuma araçlarını aynı kopyaya
bağlar. Boş `.cross-review/frozen-diff.patch` de `context` paketinde açıkça
"tracked diff yok" işaretiyle yer alır.
`finish_reason=length` ve boş final geçerli rapor değildir. Büyük denetimlerde
DeepSeek'in düşünme çıktısı uzun sürebilir. Bağlam paketi tamsa aynı açık
devir isteği kapsamında önce `context` ve `-DeepSeekReasoningEffort none`
değerlendir; büyük/eksik bağlamda `read-tools` kullan. Tekrarların token
tüketimini ve kullanılan erişim/eforu sonuçta açıkça bildir.

`read-tools` büyük projede tüm dosyaları peşinen göndermez: işçi ihtiyaç
duyduğu dosyaları açar; `list_files` ve `search_text` sayfalıdır. Git'in
gördüğü `dist`, `build` ve benzeri dizinlerdeki dosyalar da keşfedilebilir.
16 araç turundan sonra işçi, okuduklarına dayanarak son yanıt vermeye zorlanır;
yanıt yine eksikse sonuç dosyası kısmi durumla saklanır. Okuma kanıtı eksik gelirse
en fazla iki düzeltme turu denenir. `verified_project_access` yalnız seçilen
gizli sınama satırının dosya yolu ve satır numarasıyla tam eşleştiğini gösterir;
işçinin tüm mimariyi taradığını veya diğer iddialarının doğru olduğunu
kanıtlamaz. 180.000 karakter sınırına çarpan `context` koşusunu
başarılı sayma; görevin gerektirdiği kapsamda `read-tools` seç.

DeepSeek'in iki erişim modunda `.env*`, `*.env`, `*.tfvars*`,
`.docker/`, kimlik bilgisi ve özel anahtar dosyaları varsayılan olarak
listelenmez, okunmaz ve bağlama eklenmez.
Git tarafından yok sayılan dosyalar da varsayılan dışındadır. Kullanıcı
bu dosyaların gönderilmesini **özellikle** isterse ilgili
`-DeepSeekIncludeSensitive` ve/veya `-DeepSeekIncludeIgnored` seçeneğini
ver. Yok sayılan `.env` için ikisi de gerekir. Bu seçenekler dosyanın
API'ye aktarılmasına izin verir; normal proje gönderme izninden çıkarma.
İkili/UTF-8 olmayan dosyalar ile üretilmiş kilit dosyalarının yolları
bağlam paketinde açıkça listelenir; metin içerikleri gönderilmez. Diğer
metin dosyalarında dosya başına 60 KB, paket genelinde 180.000 karakter
sınırı vardır. `CONTEXT_COMPLETE` bu kapsamda aktarılabilir UTF-8 metni
ifade eder. Paket sınırı yüzünden atlanan metin dosyası
`context` modunda eksik bağlam sayılır, gerekçeli listeyle canlı çağrıdan
önce durur. `read-tools` ile yalnız gerekli dosyalar okunabilir.

Başlatıcı **ajan yetkilerini daraltmaz**: Codex sandbox'ını yalnız görev
gerektiriyorsa `-CodexSandbox` ile seç, Grok'un web ve alt ajanlarını varsayılan
olarak kapatma. `agy` başsız çağrıda terminal araçlarını da kullanabilsin diye
mevcut `--dangerously-skip-permissions` yolunu kullanır. Dış eylem ve
geri dönüşsüz işlem yetkisi yine asıl kullanıcı isteğinin kapsamındadır.

Codex'te `--skip-git-repo-check` yalnız doğrulanan **Git dışı** klasörde
eklenir. Başlatıcı prompt'u UTF-8 dosyaya yazar, Codex'in stdin'ini yazdıktan
sonra kapatır; diğer işçilerin stdin'ini de kapatır. Argümanları shell string
olarak birleştirmez. Windows yolunda Türkçe karakter, boşluk ve tırnak olasılıkları
için bu yöntem kullanılmalı.

Başlatıcının döndürdüğü `status.json` yolunu aç. `verified_project_access`
**seçilen sınama satırının tam eşleşmesi + final çıktı + başarılı süreç**
demektir. Native CLI işçisinin dosyayı hangi araçla açtığı ayrıca izlenmez.
Kanıt işaretçisi yanıtın ilk karakterinde değilse de gerçek dosya satırı ve
numarasıyla doğrulanır; `proof_at_start: false` biçim sapmasını gösterir.
`launch_prepared`, `unverified`, `failed` veya `timed_out` durumunu bitmiş iş
sayma. `final.txt`, `stdout.log`, `stderr.log` ve varsa gerçek dosya diff'ini
incele. Çıkış kodu 0, modelin başarılı çalıştığını garanti etmez. `status.json`
içindeki `requested_model` servis edilen modelin kanıtı değildir;
`observed_model` boşsa bilinmiyor de. DeepSeek API yanıtındaki `model` alanı
`observed_model` olarak kaydedilir. Başlatıcı takılı süreci zaman aşımında
süreç ağacıyla kapatır; dış aracın kendi timeout'u ayrıca yeterli olmalı.

İşçi finalinde `DELEGATE_RESULT_JSON_BEGIN` / `DELEGATE_RESULT_JSON_END`
arasındaki JSON sonuç bloğunu iste. Başlatıcı kimlik, Git başlangıcı, okunan
ve değişen dosyalar, testler, kanıtlar, engeller ve iş durumu alanlarını
`status.json.result_contract` içinde doğrular. `worker_reported_completed`
erişim durumundan ayrıdır. Sözleşme varsayılan olarak zorunludur: eksik veya
geçersiz blok `outcome: invalid_result_contract` ve başarısız çıkış verir;
erişim kanıtı ayrı `status` alanında kalır. Eski işçiyle bilinçli uyumluluk
gerekiyorsa yalnız eksik blok için `-AllowMissingResultContract` kullanılabilir.
`worker_reported_completed` işçinin beyanıdır; modelin beyan ettiği test ve
kanıtlar yine bağımsız denetim gerektirir.

## 3. Görev notu

`TaskFile` içinde kısa ama denetlenebilir görev yaz:

1. Amaç, proje/alt proje, son değişiklikler ve başlangıç commit'i/ağaç durumu.
2. Ölçülmüş zemin (`dosya:satır`); önceki bulguyu taban ver, “oraya bakma” deme.
3. Yapılacak iş, gerekiyorsa dokunulacak arayüzler ve gerçek kapsam sınırları.
4. Beklenen test/çalıştırma ve raporda istenen değişen dosyalar, kanıtlar,
   blokörler. Yanlış bir öncül bulursa durup bildirmesini iste.

Proje talimatlarını (`AGENTS.md`, `CLAUDE.md`) ve ilgili README/kodu işçinin
okumasını iste; yalnız bunların adını prompt'a yazmak erişim kanıtı değildir.
İşçinin geçici notunu sonuç klasöründe tut; paralel ajanlar proje talimat
dosyalarını birbirinin altında düzenlemesin.

## 4. Gelen sonucu bağımsız denetle

Rapor iddia listesidir. `status.json` ve final'i aç; `taskRoot`, `gitRoot`,
başlangıç `HEAD`, başlangıç kirli ağaç, erişim kanıtı ve çalışmanın sonundaki
diff'i karşılaştır. Kod değiştiyse gerçek dosyaları ve çağıranlarını aç,
gerekli testleri kendin koş; işçinin test sayısını veya alıntısını kopyalama.
Sıfır bulgu için pozitif kontrol, kritik bulgu için somut hata senaryosu ara.
Süreç 0 dönüp final üretmediyse veya dosyayı açmadıysa inceleme geçersizdir.

## Farklı görevleri paralel işçilere ver

Kullanıcı "Gemini'ye A, Grok'a B, Astra'ya C yaptır" gibi **ayrı görevler**
verirse [`scripts/Invoke-ParallelTasks.py`](scripts/Invoke-ParallelTasks.py)
kullan. Bu yol her işçi için ayrı `TaskFile` ile `Invoke-Delegate.ps1` başlatır;
hepsinin `taskRoot` değeri aynı aktif proje klasörüdür. **Proje kopyası
oluşturmaz.** `Invoke-CrossReview.py` farklı görev dağıtımı için kullanılmaz;
o, aynı görevin bağımsız denetimi içindir. Bir işçiye aynı anda iki farklı
görev verme veya görev metinlerini tek ortak nota birleştirme.

Plan dosyasını sonuç klasörü gibi proje dışında hazırla. `workers` içinde iki
veya üç ayrı görev bulunur. `provider` değerleri `agy` (Gemini), `grok`,
`codex` (Astra için `model: gpt-6-astra`) veya `deepseek` olabilir. Her işçiye
ayrı, mutlak `task_file` yolu ver; isteğe bağlı `model`, `effort`, `probe_file`
ve `timeout_seconds` yalnız ilgili işçiye uygulanır. Örnek:

```json
{"workers":[
  {"id":"gemini","provider":"agy","model":"gemini-3.8-flash-high","effort":"high","task_file":"C:\\gorevler\\gemini.txt"},
  {"id":"grok","provider":"grok","model":"grok-4.7","effort":"xhigh","task_file":"C:\\gorevler\\grok.txt"},
  {"id":"astra","provider":"codex","model":"gpt-6-astra","effort":"high","task_file":"C:\\gorevler\\astra.txt"}
]}
```

```powershell
python (Join-Path $HOME '.claude\skills\delegate-and-audit\scripts\Invoke-ParallelTasks.py') `
  --task-root '<aktif projenin mutlak yolu>' --plan-file '<plan.json>' `
  --run-dir '<proje dışı boş sonuç klasörü>' --requested-by-user
```

Model çağrısı olmadan yönlendirmeyi görmek için `--dry-run` kullan. Canlı
çalışma kullanıcının açık devir isteği olmadan başlatılmaz. `parallel-status.json`
her işçinin ayrı sonucunu gösterir; ana ajan sonuçları, testleri ve değişen
dosyaları bağımsız inceler. Paylaşılan kökte tek işçinin `changed_files`
karşılaştırması ertelenir ve tek işçi sonucu `pending_parallel_group_check`
kalır; paralel komut işçilerin bildirdiği dosyaların
birleşimini başlangıç/son proje durumu ve Git index'iyle karşılaştırır.
`individual_attribution_verified: false` her dosyanın hangi işçiye ait olduğunun
bağımsız kanıtı olmadığını belirtir. Farklı görevlere çakışmayan dosya
sahipliği ver. Görevlerin hangi dosyaları değiştireceği belirsiz veya
ortaksa yazma işlerini sırala ya da açıkça seçilmiş ayrı worktree kullan;
doğrudan ortak kök bu tür yazma çatışmalarını engellemez.

## Aynı görevi çapraz denetle

Kullanıcı açıkça **çoklu model/çapraz denetim** isterse seçtiği iki veya üç
**farklı sağlayıcı ailesine** aynı dondurulmuş `HEAD`/diff ve görev amacını
ver; her işçi kendi proje kopyasındaki dosyaları açabilsin.
Windows'ta bunun için ayrı `scripts/Invoke-CrossReview.py` komutunu kullan.
Canlı koşu ancak `--requested-by-user` ile başlar. `--dry-run` model
çağırmadan iki veya üç eşit Git çalışma ağacı kopyası ve manifest hazırlar. Koşu
klasörü kaynak proje dışında ve boş olmalıdır. Kopyalar tracked değişiklikleri
ve Git tarafından yok sayılmayan untracked dosyaları içerir; hassas dosyalar
varsayılan olarak dışlanır. Diff hassas dosya değişikliği içeriyorsa model
çağrısından önce durur. Gerekli ama Git tarafından yok sayılan **hassas olmayan**
bir dosyayı `--include-path <taskRoot'a göre yol>` ile açıkça ekle.
Checkout edilmiş alt modülün dosyaları da `.git` verisi hariç kopyalanır;
checkout edilmemiş alt modülde koşu durur. Git HEAD, tam
tracked diff, dosya hash'leri ve her işçinin ayrı durumu kaydedilir.

```powershell
python (Join-Path $HOME '.claude\skills\delegate-and-audit\scripts\Invoke-CrossReview.py') `
  --task-root '<aktif Git proje kökü>' --task-file '<UTF-8 görev notu>' `
  --run-dir '<proje dışı boş sonuç klasörü>' `
  --provider-a codex --provider-b deepseek --requested-by-user
```

Bu örnekteki sağlayıcılar, o anki kullanıcı isteğine göre seçilir; varsayılan
çift veya üçlü yoktur. Kullanıcı "bu değişikliği Gemini 3.8 Flash High ve Grok 4.7
High ile çapraz denetle" diyebilir. `agy` ve `grok` aynı dondurulmuş kopyayı
ayrı ayrı inceler; model seçimi ve eforu koşuya açıkça aktar:

```powershell
python (Join-Path $HOME '.claude\skills\delegate-and-audit\scripts\Invoke-CrossReview.py') `
  --task-root '<aktif Git proje kökü>' --task-file '<UTF-8 görev notu>' `
  --run-dir '<proje dışı boş sonuç klasörü>' --requested-by-user `
  --provider-a agy --model-a gemini-3.8-flash-high --effort-a high `
  --provider-b grok --model-b grok-4.7 --effort-b high
```

Üç model açıkça istenirse `--provider-c` ekle; üç sağlayıcının hepsi
farklı olmalıdır. Üçüne de aynı snapshot kimliği ve görev metni gider:

```powershell
python (Join-Path $HOME '.claude\skills\delegate-and-audit\scripts\Invoke-CrossReview.py') `
  --task-root '<aktif Git proje kökü>' --task-file '<UTF-8 görev notu>' `
  --run-dir '<proje dışı boş sonuç klasörü>' --requested-by-user `
  --provider-a codex --model-a gpt-6-sol --effort-a high `
  --provider-b grok --model-b grok-4.7 --effort-b high `
  --provider-c agy --model-c gemini-3.8-flash-high --effort-c high
```

`--model-a/b/c` ve `--effort-a/b/c` verilmezse seçilen sağlayıcının tek işçi
varsayılanları geçerlidir: Codex `gpt-6-sol/high`, Grok `grok-4.7/xhigh`,
Gemini `gemini-3.8-flash-high` ve DeepSeek `deepseek-v4-pro/high`.
Grok 4.7 CLI'nın en yüksek geçerli eforu `xhigh`tır; `max` istenirse
başlatıcı bunu `xhigh` olarak uygular ve `effective_effort` alanında gösterir.
Grok'un varsayılan süre sınırı 2.700 saniye (45 dakika); diğer sağlayıcılarda
900 saniyedir. Çapraz çağrıda açık `--timeout-seconds` bütün işçilere uygulanır;
Grok'u ayrı ayarlamak için `--grok-timeout-seconds` kullan. Tek işçi
başlatıcısında açık `-TimeoutSeconds` varsayılanı geçersiz kılar. Bu sınır
artışı Grok'un mutlaka final üreteceği anlamına gelmez.
Gemini'de eforu model adındaki `-low/-medium/-high` soneki belirler;
varsayılan modele farklı efor verilirse sonek güncellenir. Açık Gemini model adıyla
çelişen efor reddedilir. Diğer agy model adları aynen korunur; efor verilirse
`--effort` ile iletilir. DeepSeek'in HTTP isteği, işçinin kalan süre bütçesini
kullanır; sonuç `finish_reason: length` ile kesilirse tamamlanmış sayma.
Gemini'de 20.000 karakteri aşan istem `stream-json` ile standart girdiden
gönderilir; kısa istemlerde normal `--print` kullanılır. Uzun istemin iletilmesi
modelin bağlam penceresine sığacağını garanti etmez; sağlayıcı yanıtını denetle.
Çapraz mod iki veya üç farklı sağlayıcı ister; model kimliğinin o CLI hesabında
gerçekten erişilebilir olup olmadığını canlı koşu gösterir. Normal
`Invoke-Delegate.ps1` çağrısı çapraz denetimi
**başlatmaz**. İki veya üç yanıt eşit kaynak kopyalarından gelse de model bulguları
`result_claims_verified: false` ile kaydedilir; ana ajan dosya ve testlerle
denetleyene kadar doğrulanmış bulgu sayılmaz. Kopyanın iş sırasında değişmesi
sonuçta görünür ve koşu eksik sayılır. Bazı sağlayıcılar işletim sistemi
düzeyinde salt okunur çalışmadığı için anlık değişmezlik garantisi verme.
Kirli Git başlangıcında `changed_files`, ilk durumdaki dosya ve index
kimlikleriyle son durum karşılaştırılarak denetlenir; başlangıçta kirli olup
işçinin dokunmadığı dosyalar değişiklik sayılmaz. HEAD değişirse başlangıç ve
son commit farkı da bu karşılaştırmaya katılır; fark okunamazsa rapor geçerli
sayılmaz. Bu denetim Git'in gördüğü
dosyalarla sınırlıdır; yok sayılan dosyalar kapsama girmez ve
`status.json.changed_files_scope` bu sınırı açıkça gösterir. Çapraz denetim
kaynak bütünlüğünü yok sayılan dosyalar dahil ayrıca hash'ler. Yalnız `.cmd/.bat` bulunan
yaygın npm Node başlatıcıları gerçek `.js` girişine güvenli biçimde çözülür;
tanınmayan batch dosyası açık ön kontrol hatası verir.
İşçi kopyasında Git keşfi kopyanın üst dizininde durdurulur; üstteki gerçek
depoya yanlışlıkla bağlanamaz. Projede kök README bulunmasa da uygun metin
dosyası okuma kanıtı için seçilir. Eksik checkout edilmiş alt modül varsa
model çağrısından önce durulur.
Çapraz işçilerde Python bytecode üretimi kapatılır; salt okunur incelemede
`__pycache__` oluşması kopya bütünlüğünü gereksiz yere bozmaz. Başka üretilen
dosyalar yine snapshot değişikliği olarak raporlanır.
Codex için `--codex-sandbox read-only` isteğe bağlıdır; bu Windows ortamında
model ağına da engel olabildiği ölçüldü. Varsayılan çapraz denetim ayrı
kopyalar ve son hash kontrolü kullanır, kaynak projeyi işçiye açmaz.
İşçilerden sonra kaynak ağaçtaki dosyalar (Git tarafından yok sayılanlar dahil)
yeniden hash'lenir; değişiklik `source_unchanged_after_workers: false` ve
`review_incomplete` üretir. Bu tespit mekanizması işletim sistemi düzeyinde
yazmayı engellemez. `.git` içindeki yönetim dosyaları bu tam dosya taramasına
dahil değildir; HEAD/diff/status ayrıca karşılaştırılır.
Bulgu başına konum, etki, yeniden üretim/kanıt ve önerilen düzeltmeyi iste.
Ana ajan her bulguyu gerçek kod/testle sınıflandırır: `VERIFIED`,
`CROSS_REVIEWED`, `UNVERIFIED`, `REFUTED` (olumlu karşı kanıtla) veya `FAILED`
(erişim/çalışma hatası). Oy çoğunluğu doğruluk kanıtı değildir. Kritik
uyuşmazlıkta önce yerel yeniden üretim yap; taze farklı model çağrısı ancak
Kullanıcı açıkça isterse yapılır. Sessiz bulguyu “çürütülmüş” sayma. Çoklu model
modunu tek işçi devrinden veya sıradan incelemeden otomatik başlatma.

Paralel **yazıcı** gerekiyorsa ayrı worktree veya açık dosya sahipliği seç;
tek işçi ve salt okunur denetim için buna ihtiyaç yok. Tamamlanan işte
değişen dosyaları, testleri, açık kalan iddiaları ve gerçekten yapılmayan
dış eylemleri açıkça bildir.
