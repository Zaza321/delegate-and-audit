# Sağlayıcı notları

Bu belge makineye ve hesaba özel eski ölçümleri içermez. Kullanılacak CLI'nın `--help`, `--version` ve hesap/model erişimini kendi kurulumunuzda doğrulayın. Aşağıdaki varsayılanlar skill'in 2026-09-24 sürümündeki seçimleridir; sağlayıcıların her hesapta modeli sunacağına dair garanti değildir.

## Codex

`codex exec` proje köküyle `-C` kullanır. Başlatıcı `gpt-6-sol` ve `high` eforunu açık geçirir; `-Model gpt-6-astra` gibi seçim mümkündür. Git dışı klasörde `--skip-git-repo-check` eklenir. `status.json.observed_model` boş olabilir; istenen model ile servis tarafından dönen modeli eş tutmayın. `-CodexSandbox` istenirse çalışma izinlerini belirler; Windows'ta `read-only` ağ erişimini de etkileyebilir.

## Grok

`grok` CLI proje kökünü `--cwd` ile alır. Varsayılan `grok-4.7/xhigh`, süre sınırı 2700 saniyedir. `max` efor isteği `xhigh` olarak uygulanır; `effective_effort` alanını okuyun. CLI'nın gerçek komut bayrakları ön kontrolde doğrulanır. Sürenin artması tam final garantisi değildir.

## Gemini (`agy`)

`agy` CLI mutlak proje kökünü `--add-dir` ile alır. `--project` klasör yolu değildir. Varsayılan model `gemini-3.8-flash-high`; `-AgyReasoningEffort` efor seçimi ile model sonekinin çelişmesi reddedilir. Büyük istemlerde `stream-json` üzerinden stdin kullanılır. Başsız kipte terminal araç izinleri geniş olabilir; görev kapsamı önemlidir.

## DeepSeek

Yerel CLI yerine API çağrısı yapılır. Varsayılan `deepseek-v4-pro/high`, `context` kipidir. Klasör yolunu API'ye vermek erişim sağlamaz; bu kip uygun dosyaların içeriklerini gönderir. Paket sınırına çarpan koşu başlamadan durur. `read-tools` kipinde yalnız `list_files`, `read_file`, `search_text` bulunur ve büyük projede ihtiyaç duyulan dosyalar okunur. UTF-8 olmayan/ikili dosya içerikleri gönderilmez. `Set-DeepSeekKey.ps1` yalnız Windows kullanıcı hesabına bağlı şifreli depo için etkileşimli kurulumdur; alternatif olarak `DEEPSEEK_API_KEY` kullanın.

## Üç akışın farkı

- Tek devir: bir işçi gerçek `taskRoot` üzerinde çalışır.
- Paralel görev: iki/üç farklı görev, aynı `taskRoot`; çakışan yazma riskini yönetin.
- Çapraz denetim: aynı görev, iki/üç farklı sağlayıcı ve ayrı snapshot kopyaları; kaynak ve kopya bütünlüğü kontrol edilir.

`status.json`, `parallel-status.json` veya `review-status.json` sonucunu ve gerçek diff'i inceleyin. Gerçek CLI sürümü ile model erişimi değişirse önce `-DryRun` / `--dry-run` yapın; canlı sonucu yine ayrıca doğrulayın.
