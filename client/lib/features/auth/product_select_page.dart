import 'package:flutter/material.dart';

import '../../core/network/ws_client.dart';

class ProductSelectPage extends StatefulWidget {
  const ProductSelectPage({
    super.key,
    required this.client,
    required this.logout,
  });

  final WsClient client;
  final VoidCallback logout;

  @override
  State<ProductSelectPage> createState() => _ProductSelectPageState();
}

class _ProductSelectPageState extends State<ProductSelectPage> {
  String? selected;
  bool busy = false;
  String error = '';

  @override
  void initState() {
    super.initState();
    selected =
        widget.client.productCode ??
        (widget.client.products.isEmpty
            ? null
            : widget.client.products.first['code']?.toString());
  }

  Future<void> confirm() async {
    final code = selected;
    if (code == null || busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await widget.client.selectProduct(code);
    } catch (exception) {
      if (mounted) {
        setState(() {
          error = exception is StateError ? exception.message : '产品切换失败';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final products = widget.client.products;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择产品'),
        actions: [
          TextButton(
            onPressed: busy ? null : widget.logout,
            child: const Text('退出登录'),
          ),
        ],
      ),
      body: SafeArea(
        child: products.isEmpty
            ? const Center(child: Text('服务端未配置可用产品，请联系管理员'))
            : Column(
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('登录成功，请选择要接入的产品'),
                    ),
                  ),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: products.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final product = products[index];
                        final code = product['code']?.toString();
                        final active = code != null && code == selected;
                        return ListTile(
                          enabled: !busy,
                          onTap: () => setState(() => selected = code),
                          leading: Icon(
                            active
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            color: active ? theme.colorScheme.primary : null,
                          ),
                          title: Text(
                            product['name']?.toString() ?? code ?? '',
                          ),
                          subtitle: Text(
                            '${code ?? ''} · ${product['url'] ?? ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      },
                    ),
                  ),
                  if (error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Text(
                        error,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: selected == null || busy ? null : confirm,
                        child: busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('进入产品'),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
