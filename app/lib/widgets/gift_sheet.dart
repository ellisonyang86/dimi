import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/client.dart';
import '../theme.dart';

const List<int> kGiftDenominations = [1, 5, 10, 52, 100];

Future<void> showMomentGiftSheet(BuildContext context, int momentId,
        {VoidCallback? onSuccess}) =>
    _showGift(context, send: (amount, key) async {
      await context
          .read<DimiApi>()
          .sendMomentGift(momentId, amount, requestKey: key);
    }, onSuccess: onSuccess);

Future<void> showHometownGiftSheet(BuildContext context, int contentId,
        {VoidCallback? onSuccess}) =>
    _showGift(context,
        send: (amount, key) => context
            .read<DimiApi>()
            .sendHometownGift(contentId, amount, requestKey: key),
        onSuccess: onSuccess);

Future<void> _showGift(BuildContext context,
    {required Future<void> Function(int, String) send,
    VoidCallback? onSuccess}) async {
  final api = context.read<DimiApi>();
  final amount = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => _GiftSheet(api: api, send: send));
  if (amount == null || !context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text('已送出 $amount 觅豆心意')));
  onSuccess?.call();
}

class _GiftSheet extends StatefulWidget {
  const _GiftSheet({required this.api, required this.send});
  final DimiApi api;
  final Future<void> Function(int, String) send;
  @override
  State<_GiftSheet> createState() => _GiftSheetState();
}

class _GiftSheetState extends State<_GiftSheet> {
  int? _balance;
  int _amount = 1;
  bool _loading = true, _sending = false, _uncertain = false;
  String? _error;
  String _requestKey = newIdempotencyKey();
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final wallet = await widget.api.wallet();
      if (mounted) setState(() => _balance = wallet.balance);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    if (_sending || _balance == null || _amount > _balance!) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.send(_amount, _requestKey);
      if (!mounted) return;
      setState(() {
        _sending = false;
        _uncertain = false;
      });
      Navigator.pop(context, _amount);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _uncertain = e.code == -1 || e.code >= 50000;
        _error = _uncertain ? '暂未确认发送结果，请在此重试确认，避免重复打赏。' : e.message;
        if (!_uncertain) _requestKey = newIdempotencyKey();
      });
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_sending,
        child: SafeArea(
            child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              const Expanded(
                  child: Text('赏一份心意',
                      style: TextStyle(
                          fontSize: 21, fontWeight: FontWeight.w600))),
              IconButton(
                  tooltip: '关闭打赏',
                  onPressed: _sending ? null : () => Navigator.pop(context),
                  icon: const Icon(Icons.close)),
            ]),
            const SizedBox(height: 8),
            Text('我的余额：${_balance ?? '—'} 觅豆',
                style: const TextStyle(fontSize: 16, color: kDimiGray66)),
            const SizedBox(height: 16),
            if (_loading)
              const CircularProgressIndicator()
            else
              Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: kGiftDenominations
                      .map((d) => ChoiceChip(
                            label: Text('$d 觅豆'),
                            selected: _amount == d,
                            onSelected: _sending ||
                                    _uncertain ||
                                    _balance == null ||
                                    d > _balance!
                                ? null
                                : (_) => setState(() {
                                      _amount = d;
                                      _requestKey = newIdempotencyKey();
                                      _error = null;
                                    }),
                            labelStyle: const TextStyle(fontSize: 17),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 12),
                          ))
                      .toList()),
            if (_balance == 0)
              const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text('觅豆余额不足，可到“我 → 觅豆钱包”签到或完成任务。',
                      textAlign: TextAlign.center)),
            if (_error != null)
              Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!,
                      style:
                          const TextStyle(fontSize: 15, color: kDimiDanger))),
            if (!_loading && _balance == null)
              TextButton(onPressed: _load, child: const Text('重新获取余额')),
            const SizedBox(height: 20),
            SizedBox(
                width: double.infinity,
                child: FilledButton(
                    onPressed: _sending ||
                            _loading ||
                            _balance == null ||
                            _amount > _balance!
                        ? null
                        : _send,
                    child: Text(_sending
                        ? '正在送出…'
                        : _uncertain
                            ? '重试确认'
                            : '确认打赏 $_amount 觅豆'))),
            const SizedBox(height: 12),
            const Text('觅豆来自任务赠送，纯表心意，不支持充值或提现。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: kDimiGray66)),
          ]),
        )),
      );
}
