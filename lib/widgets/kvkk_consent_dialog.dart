import 'package:flutter/material.dart';

/// Modal that displays the KVKK + liability disclaimer for video verification
/// recording. Shows a scrollable terms area; the "Kabul Ediyorum" button is
/// disabled until the user scrolls to the bottom.
///
/// Returns `true` if the user accepts, `false` (or `null` on dismiss) otherwise.
class KvkkConsentDialog extends StatefulWidget {
  const KvkkConsentDialog({super.key});

  static Future<bool> show(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const KvkkConsentDialog(),
    );
    return result ?? false;
  }

  @override
  State<KvkkConsentDialog> createState() => _KvkkConsentDialogState();
}

class _KvkkConsentDialogState extends State<KvkkConsentDialog> {
  final ScrollController _scrollController = ScrollController();
  bool _scrolledToBottom = false;
  bool _checkboxAccepted = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scrolledToBottom &&
        _scrollController.offset >=
            _scrollController.position.maxScrollExtent - 24) {
      setState(() => _scrolledToBottom = true);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canAccept = _scrolledToBottom && _checkboxAccepted;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Row(
                children: const [
                  Icon(Icons.privacy_tip_rounded,
                      color: Color(0xFF1D8AD6), size: 28),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Video Doğrulama — KVKK Aydınlatma & Sorumluluk Reddi',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: Color(0xFF0F5191),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Scrollbar(
                controller: _scrollController,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      _Section(
                        title: '1. Veri Sorumlusu',
                        body:
                            'MedTrack Plus ("Uygulama"), 6698 sayılı Kişisel '
                            'Verilerin Korunması Kanunu ("KVKK") kapsamında veri '
                            'sorumlusu sıfatıyla hareket etmektedir. Bu metin, '
                            'video doğrulama özelliğini etkinleştirdiğinizde '
                            'işlenecek kişisel verileriniz hakkında sizi '
                            'bilgilendirmek amacıyla hazırlanmıştır.',
                      ),
                      _Section(
                        title: '2. İşlenen Kişisel Veriler',
                        body:
                            'Bu özelliği etkinleştirdiğinizde, ilaç alım '
                            'doğrulama oturumları sırasında ön kameranızla '
                            'kaydedilen kısa video parçaları işlenir. Kayıtlar '
                            'yüz görüntünüzü ve hap alımına ilişkin görsel '
                            'verileri içerebilir. Ayrıca cihaz tanımlayıcısı, '
                            'oturum zaman damgası, doğrulama skoru ve '
                            'sınıflandırma sonucu gibi teknik veriler '
                            'işlenmektedir.',
                      ),
                      _Section(
                        title: '3. İşleme Amacı ve Hukuki Sebep',
                        body:
                            'Veriler yalnızca ilaç alım doğrulamasını '
                            'sağlamak, hasta yakınlarına bilgi vermek ve hizmet '
                            'kalitesini iyileştirmek amacıyla işlenir. Hukuki '
                            'sebep KVKK m.5/1 uyarınca AÇIK RIZA\'nızdır. '
                            'Onayınız olmadan hiçbir video kaydı alınmaz, '
                            'sunucuya yüklenmez veya saklanmaz.',
                      ),
                      _Section(
                        title: '4. Saklama Süresi',
                        body:
                            'Yüklenen videolar Firebase Storage üzerinde '
                            'oturum başına yalnızca 24 saat süreyle saklanır '
                            've bu sürenin sonunda otomatik olarak silinir. '
                            'Doğrulama meta verileri (skor, zaman damgası vb.) '
                            'ise hizmet kayıtları için Firestore üzerinde tutulur.',
                      ),
                      _Section(
                        title: '5. Aktarım',
                        body:
                            'Video kaydı yalnızca sizin yetkilendirdiğiniz '
                            'hasta yakınlarınız (relative) tarafından, oturum '
                            'açtıkları yetkili hesap üzerinden görüntülenebilir. '
                            'Üçüncü kişilere veya reklam amaçlı hiçbir kuruma '
                            'aktarılmaz.',
                      ),
                      _Section(
                        title: '6. Haklarınız',
                        body:
                            'KVKK m.11 uyarınca; verilerinize erişme, '
                            'düzeltilmesini, silinmesini veya işlenmesinin '
                            'durdurulmasını talep etme hakkına sahipsiniz. Bu '
                            'taleplerinizi uygulama içi Ayarlar bölümünden '
                            '"Video Doğrulama Kaydı" anahtarını kapatarak veya '
                            'plus.medtrack@gmail.com adresine yazarak '
                            'iletebilirsiniz.',
                      ),
                      _Section(
                        title: '7. Sorumluluk Reddi',
                        body:
                            'Video doğrulama, yapay zeka tabanlı bir destek '
                            'aracıdır ve %100 doğruluk garantisi vermez. Sistem '
                            'çıktıları tıbbi tavsiye yerine geçmez. MedTrack '
                            'Plus ekibi, hatalı pozitif/negatif sonuçlardan, '
                            'eksik kayıtlardan veya kullanıcının ilacı düzgün '
                            'şekilde alıp almamasından doğacak sağlık '
                            'sonuçlarından sorumlu tutulamaz. İlaç tedavisine '
                            'ilişkin tüm sorumluluk kullanıcıya ve onun '
                            'sağlık hizmeti sağlayıcısına aittir.',
                      ),
                      _Section(
                        title: '8. Açık Rıza Beyanı',
                        body:
                            'Yukarıdaki tüm maddeleri okuduğumu, anladığımı; '
                            'video kaydının alınmasına, sunucuda 24 saat '
                            'saklanmasına, hasta yakınlarımla paylaşılmasına '
                            've sonrasında otomatik silinmesine açık rızamla '
                            'onay verdiğimi kabul ve beyan ederim. Bu onayı '
                            'dilediğim zaman Ayarlar üzerinden geri '
                            'alabileceğimi biliyorum.',
                      ),
                      SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  Checkbox(
                    value: _checkboxAccepted,
                    onChanged: _scrolledToBottom
                        ? (v) => setState(() => _checkboxAccepted = v ?? false)
                        : null,
                  ),
                  Expanded(
                    child: Text(
                      _scrolledToBottom
                          ? 'Yukarıdaki metnin tamamını okudum ve kabul ediyorum.'
                          : 'Devam etmek için lütfen metni sonuna kadar kaydırın.',
                      style: TextStyle(
                        fontSize: 13,
                        color: _scrolledToBottom
                            ? const Color(0xFF334155)
                            : Colors.grey.shade500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Reddet'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1D8AD6),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.grey.shade300,
                    ),
                    onPressed: canAccept
                        ? () => Navigator.of(context).pop(true)
                        : null,
                    child: const Text('Kabul Ediyorum'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String body;
  const _Section({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: Color(0xFF0F5191),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            body,
            style: const TextStyle(
              fontSize: 13.5,
              height: 1.5,
              color: Color(0xFF334155),
            ),
          ),
        ],
      ),
    );
  }
}
