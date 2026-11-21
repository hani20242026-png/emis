import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as win_wv;

class EmisLiveSync extends StatefulWidget {
  final String url;
  final String mode;
  final String entity;
  final String token;
  final String? recordId;
  final bool ignoreInitialSnapshot;
  final Map<String, List<String>> aliases;
  final ValueChanged<Map<String, String>> onSnapshot;
  final ValueChanged<Map<String, List<Map<String, dynamic>>>>? onOptions;
  final ValueChanged<Map<String, Map<String, dynamic>>>? onSchema;
  final ValueChanged<String>? onStatus;

  const EmisLiveSync({
    super.key,
    required this.url,
    required this.mode,
    required this.entity,
    required this.token,
    required this.aliases,
    required this.onSnapshot,
    this.onOptions,
    this.onSchema,
    this.recordId,
    this.ignoreInitialSnapshot = false,
    this.onStatus,
  });

  @override
  State<EmisLiveSync> createState() => EmisLiveSyncState();
}

class EmisLiveSyncState extends State<EmisLiveSync> {
  WebViewController? _mobileController;
  win_wv.WebviewController? _windowsController;
  StreamSubscription<dynamic>? _windowsMessageSubscription;
  Timer? _windowsBridgeRetry;
  bool _windowsBridgeAttemptInProgress = false;
  bool get _isWindows => Platform.isWindows;
  bool _ready = false;
  bool _injectingToken = false;
  bool _hasPushedValues = false;
  DateTime? _firstPushAt;

  @override
  void initState() {
    super.initState();
    if (_isWindows) {
      _initWindowsWebView();
    } else {
      _initMobileWebView();
    }
  }

  void _handleBridgeMessage(String message) {
    try {
      final decoded = jsonDecode(message);
      if (decoded is! Map) return;
      final type = '${decoded['type'] ?? ''}';
      if (type == 'status') {
        widget.onStatus?.call('${decoded['message'] ?? ''}');
        return;
      }
      if (type == 'focus') {
        widget.onStatus?.call('مزامنة الحقل: ${decoded['field'] ?? ''}');
        return;
      }
      if (type == 'schema') {
        final raw = decoded['fields'];
        if (raw is! Map) return;
        final schema = <String, Map<String, dynamic>>{};
        for (final entry in raw.entries) {
          final key = '${entry.key}'.trim();
          if (key.isEmpty || entry.value is! Map) continue;
          schema[key] = Map<String, dynamic>.from(entry.value as Map);
        }
        if (schema.isNotEmpty) widget.onSchema?.call(schema);
        return;
      }
      if (type == 'options') {
        final raw = decoded['options'];
        if (raw is! Map) return;
        final result = <String, List<Map<String, dynamic>>>{};
        for (final entry in raw.entries) {
          final key = '${entry.key}'.trim();
          final list = entry.value;
          if (key.isEmpty || list is! List) continue;
          final values = <Map<String, dynamic>>[];
          final seen = <String>{};
          for (final item in list) {
            final option = item is Map
                ? Map<String, dynamic>.from(item)
                : <String, dynamic>{'value': '$item', 'label': '$item'};
            final value = '${option['value'] ?? option['id'] ?? option['label'] ?? ''}'.trim();
            final label = '${option['label'] ?? option['displayName'] ?? option['text'] ?? value}'.trim();
            if (value.isEmpty || label.isEmpty || !seen.add('$value|$label')) continue;
            final src = '${option['_src'] ?? ''}'.trim();
            values.add({
              'value': value,
              'displayName': label,
              if (src.isNotEmpty) '_src': src,
              if (option['_complete'] == true) '_complete': true,
            });
          }
          if (values.isNotEmpty) result[key] = values;
        }
        if (result.isNotEmpty) widget.onOptions?.call(result);
        return;
      }
      if (type != 'snapshot') return;
      if (widget.ignoreInitialSnapshot &&
          (!_hasPushedValues ||
              (_firstPushAt != null &&
                  DateTime.now().difference(_firstPushAt!) <
                      const Duration(milliseconds: 1500)))) {
        return;
      }
      final raw = decoded['fields'];
      if (raw is! Map) return;
      final snapshot = <String, String>{};
      for (final entry in raw.entries) {
        final key = '${entry.key}'.trim();
        if (key.isEmpty) continue;
        snapshot[key] = '${entry.value ?? ''}';
      }
      if (snapshot.isNotEmpty) widget.onSnapshot(snapshot);
    } catch (_) {}
  }

  void _initMobileWebView() {
    final web = WebViewController();
    _mobileController = web;
    web
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel(
        'EmisSyncChannel',
        onMessageReceived: (message) => _handleBridgeMessage(message.message),
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            _ready = false;
            widget.onStatus?.call('جاري فتح صفحة EMIS للمزامنة...');
          },
          onPageFinished: (_) async {
            if (_injectingToken) return;
            final reloaded = await _injectAuthentication();
            if (reloaded) return;
            await _installBridge();
            await Future<void>.delayed(const Duration(milliseconds: 500));
            await refreshSchema();
            await Future<void>.delayed(const Duration(milliseconds: 700));
            widget.onStatus?.call('تم فتح نموذج EMIS وجلب بنيته وخياراته');
          },
          onWebResourceError: (error) {
            widget.onStatus?.call('تعذر تحميل صفحة EMIS: ${error.errorCode}');
          },
        ),
      );
    web.loadRequest(Uri.parse(widget.url));
  }

  Future<void> _initWindowsWebView() async {
    final web = win_wv.WebviewController();
    _windowsController = web;
    try {
      await web.initialize();
      await web.setBackgroundColor(Colors.transparent);
      if (mounted) setState(() {});
      _windowsMessageSubscription = web.webMessage.listen((message) {
        final text = message is String ? message : jsonEncode(message);
        _handleBridgeMessage(text);
      });
      await web.loadUrl(widget.url);
      widget.onStatus?.call('جاري فتح صفحة EMIS للمزامنة على Windows...');
      // WebView2 navigation completion can precede the application's SPA boot.
      // Retry bridge installation until the page exposes the EMIS form bridge.
      _windowsBridgeRetry?.cancel();
      var attempts = 0;
      _windowsBridgeRetry = Timer.periodic(const Duration(milliseconds: 900), (timer) async {
        if (!mounted || _ready || attempts++ >= 45) {
          timer.cancel();
          if (!_ready && mounted) {
            widget.onStatus?.call('تعذر تهيئة المزامنة الحية داخل WebView2.');
          }
          return;
        }
        if (_injectingToken || _windowsBridgeAttemptInProgress) return;
        _windowsBridgeAttemptInProgress = true;
        try {
          final reloaded = await _injectAuthentication();
          if (reloaded) return;
          await _installBridge();
        } finally {
          _windowsBridgeAttemptInProgress = false;
        }
        if (_ready) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          await refreshSchema();
          widget.onStatus?.call('تم فتح نموذج EMIS وجلب بنيته وخياراته');
          timer.cancel();
        }
      });
    } catch (error) {
      widget.onStatus?.call('تعذر تشغيل WebView2 للمزامنة: $error');
    }
  }

  /// Public bridge used by the school-card screen for platform-independent WebView access.
  Future<dynamic> runJavaScript(String script) => _runJavaScript(script);

  /// Reloads the embedded EMIS page on both Windows and mobile.
  Future<void> reloadPage() async {
    await _runJavaScript('window.location.reload();');
  }

  Future<dynamic> _runJavaScript(String script) async {
    if (_isWindows) {
      final web = _windowsController;
      if (web == null) throw StateError('WebView2 غير مهيأ');
      return web.executeScript(script);
    }
    final web = _mobileController;
    if (web == null) throw StateError('WebView غير مهيأ');
    return web.runJavaScript(script);
  }

  Future<dynamic> _runJavaScriptReturningResult(String script) async {
    if (_isWindows) {
      final web = _windowsController;
      if (web == null) throw StateError('WebView2 غير مهيأ');
      return web.executeScript(script);
    }
    final web = _mobileController;
    if (web == null) throw StateError('WebView غير مهيأ');
    return web.runJavaScriptReturningResult(script);
  }

  Future<bool> _injectAuthentication() async {
    final token = widget.token.trim();
    if (token.isEmpty) return false;

    final bearer = token.toLowerCase().startsWith('bearer ')
        ? token
        : 'Bearer $token';
    final raw = token.replaceFirst(
      RegExp(r'^Bearer\s+', caseSensitive: false),
      '',
    );

    final js = '''
(function(){
  try {
    if (sessionStorage.getItem('__EMIS_APP_AUTH_READY__') === '1') return false;
    var rawToken = ${jsonEncode(raw)};
    var bearerToken = ${jsonEncode(bearer)};
    var keys = [
      'token','access_token','accessToken','authToken','jwt',
      'Authorization','authorization','bearerToken'
    ];
    for (var i=0;i<keys.length;i++) {
      try {
        localStorage.setItem(
          keys[i],
          keys[i].toLowerCase().indexOf('authorization') >= 0
            ? bearerToken : rawToken
        );
      } catch(e) {}
      try {
        sessionStorage.setItem(
          keys[i],
          keys[i].toLowerCase().indexOf('authorization') >= 0
            ? bearerToken : rawToken
        );
      } catch(e) {}
    }
    try { localStorage.setItem('BearerToken', bearerToken); } catch(e) {}
    try { sessionStorage.setItem('BearerToken', bearerToken); } catch(e) {}
    sessionStorage.setItem('__EMIS_APP_AUTH_READY__','1');
    location.reload();
    return true;
  } catch(e) { return false; }
})();''';

    _injectingToken = true;
    try {
      final result = await _runJavaScriptReturningResult(js);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      _injectingToken = false;
      return '$result'.toLowerCase().contains('true');
    } catch (_) {
      _injectingToken = false;
      return false;
    }
  }

  Future<void> _installBridge() async {
    final aliases = jsonEncode(widget.aliases);
    final id = jsonEncode(widget.recordId ?? '');
    final mode = jsonEncode(widget.mode);
    final entity = jsonEncode(widget.entity);

    final js = '''
(function(){
  try {
    window.__EMIS_APP_BRIDGE__ = {
      aliases: $aliases,
      recordId: $id,
      mode: $mode,
      entity: $entity,
      opened: false,
      last: '',
      schemaLast: '',
      triedEmptySelects: {},
      optionsCollected: {},
      lastSchema: {},
      groupsLast: '',
      collecting: false,
      lastPush: 0
    };

    const send = (type, payload) => {
      try {
        EmisSyncChannel.postMessage(JSON.stringify(
          Object.assign({type:type}, payload || {})
        ));
      } catch(e) {}
    };

    // Quasar يتجاهل أي Escape لا يحمل keyCode=27؛ الحدث القديم لم يكن يغلق القوائم أبداً
    // فتبقى قوائم مفتوحة تلوّث التقاط القوائم التالية.
    const pressEscape = (target) => {
      ['keydown', 'keyup'].forEach(type => {
        try {
          const ev = new KeyboardEvent(type, {key:'Escape', code:'Escape', keyCode:27, which:27, bubbles:true, cancelable:true});
          (target || document).dispatchEvent(ev);
        } catch(e) {}
      });
    };

    const norm = (s) => String(s || '')
      .replace(/[\\u064B-\\u065F\\u0670]/g,'')
      .replace(/[أإآٱ]/g,'ا')
      .replace(/ة/g,'ه')
      .replace(/ى/g,'ي')
      .replace(/[\\u06CC\\u0649]/g,'ي')
      .replace(/ک/g,'ك')
      .replace(/\\s+/g,' ')
      .trim()
      .toLowerCase();

    const textOf = (el) => {
      if (!el) return '';
      try {
        const parent = el.closest('.q-field');
        if (parent) {
          const q = parent.querySelector('.q-field__label,.q-field__native-label,[data-label]');
          if (q) {
            const clone = q.cloneNode(true);
            clone.querySelectorAll('i,svg,.q-icon,[class*=icon],button').forEach(n => n.remove());
            const label = String(clone.innerText || clone.textContent || '').replace(/\\s+/g,' ').trim();
            if (label && !/^(arrow_drop_down|expand_more|keyboard_arrow_down)\$/i.test(label)) return label;
          }
          const aria = parent.getAttribute('aria-label');
          if (aria && !/^(arrow_drop_down|expand_more|keyboard_arrow_down)\$/i.test(aria.trim())) return aria.trim();
        }
      } catch(e) {}
      try {
        const id = el.getAttribute('id');
        if (id) {
          const lab = document.querySelector('label[for="' + CSS.escape(id) + '"]');
          if (lab && (lab.innerText || lab.textContent)) return String(lab.innerText || lab.textContent).trim();
        }
      } catch(e) {}
      try {
        const lab = el.closest('label');
        if (lab && (lab.innerText || lab.textContent)) return String(lab.innerText || lab.textContent).trim();
      } catch(e) {}
      for (const a of ['aria-label','placeholder','data-label']) {
        try { const v = el.getAttribute(a); if (v && v.trim()) return v.trim(); } catch(e) {}
      }
      for (const a of ['name','id','data-cy','data-test']) {
        try { const v = el.getAttribute(a); if (v && v.trim()) return v.trim(); } catch(e) {}
      }
      return '';
    };

    const candidates = (el) => {
      const out = [];
      ['id','name','aria-label','placeholder','data-cy','data-test'].forEach(a => {
        try { const v = el.getAttribute(a); if (v) out.push(v); } catch(e) {}
      });
      const t = textOf(el); if (t) out.push(t);
      return [...new Set(out.map(norm).filter(Boolean))];
    };

    const aliases = window.__EMIS_APP_BRIDGE__.aliases || {};

    const sortedAliasKeys = Object.keys(aliases).sort((a, b) => {
      const la = Math.max(...(aliases[a] || ['']).map(s => norm(s).length), 0);
      const lb = Math.max(...(aliases[b] || ['']).map(s => norm(s).length), 0);
      return lb - la;
    });

    const fieldKey = (el) => {
      const cs = candidates(el);
      for (const k of Object.keys(aliases)) {
        const aa = (aliases[k] || []).map(norm);
        if (cs.some(c => aa.includes(c))) return k;
      }
      for (const k of sortedAliasKeys) {
        const aa = (aliases[k] || []).map(norm);
        if (cs.some(c => aa.some(a => a.length >= 4 && (c === a || c.includes(a) || a.includes(c))))) return k;
      }
      const label = String(textOf(el) || '').trim();
      const q = el.closest ? el.closest('.q-field') : null;
      const generatedId = !!(q && (el.getAttribute('id') || '').match(/^(q-|input-|select-)/i));
      if (label && (!el.getAttribute('name') || generatedId)) return label;
      const raw = (el.getAttribute('name') || el.getAttribute('id') || el.getAttribute('data-cy') || el.getAttribute('data-test') || '').trim();
      if (raw) {
        const cleaned = raw.replace(/\\[(\\d+)\\]/g,'_\$1').replace(/[^a-zA-Z0-9_]/g,'_').replace(/_+/g,'_').replace(/^_+|_+\$/g,'');
        if (cleaned) return cleaned.charAt(0).toLowerCase() + cleaned.slice(1);
      }
      return label;
    };

    const readValue = (el) => {
      try {
        if (el.tagName === 'SELECT') {
          const o = el.options && el.selectedIndex >= 0 ? el.options[el.selectedIndex] : null;
          return o ? (el.value || o.textContent || '') : (el.value || '');
        }
        const q = el.closest ? el.closest('.q-field') : null;
        if (q && q.classList.contains('q-select--multiple')) {
          const chips = [...q.querySelectorAll('.q-chip__content, .q-chip')]
            .map(x => String(x.innerText || x.textContent || '').trim())
            .filter(Boolean);
          if (chips.length) return chips.join(',');
        }
        if ('value' in el) return el.value;
        return el.textContent || '';
      } catch(e) { return ''; }
    };

    const detectKind = (el) => {
      const tag = String(el.tagName || '').toLowerCase();
      const type = String(el.type || '').toLowerCase();
      if (tag === 'select') return 'select';
      if (tag === 'textarea') return 'textarea';
      if (type === 'date') return 'date';
      if (type === 'checkbox' || type === 'radio') return 'checkbox';

      const q = el.closest ? el.closest('.q-field') : null;
      if (!q) return 'text';

      if (q.classList.contains('q-select')) return 'select';
      if (q.querySelector('.q-select')) return 'select';
      if (q.getAttribute('role') === 'combobox') return 'select';
      if (q.querySelector('[role="combobox"]')) return 'select';
      if (q.querySelector('input[aria-expanded]')) return 'select';
      if (el.getAttribute('role') === 'combobox') return 'select';

      const append = q.querySelector('.q-field__append');
      if (append) {
        const icon = append.querySelector('i, svg, .q-icon, [class*="arrow"], [class*="expand"], [class*="dropdown"]');
        if (icon) {
          const iconText = (icon.textContent || '').trim();
          const iconClass = String(icon.className || '');
          if (/arrow|expand|dropdown|drop/i.test(iconText) || /arrow|expand|dropdown|drop/i.test(iconClass)) return 'select';
        }
      }
      if (el.readOnly && q.querySelector('i, svg, .q-icon')) return 'select';
      return 'text';
    };

    const isReallyVisible = (el) => {
      if (!el) return false;
      if (el.offsetParent === null) {
        try {
          const st = window.getComputedStyle(el);
          if (st.display === 'none' || st.visibility === 'hidden') return false;
        } catch(e) { return false; }
      }
      const r = el.getBoundingClientRect();
      return r.width > 0 && r.height > 0;
    };

    let lastScanTime = 0;
    let lastDomSize = 0;

    const scan = () => {
      const now = Date.now();
      const domSize = document.querySelectorAll('.q-field').length;

      if (now - lastScanTime < 80 && domSize === lastDomSize) return;
      lastScanTime = now;
      lastDomSize = domSize;

      const fields = {};
      const schema = {};
      const allInputs = [...document.querySelectorAll('input,textarea,select,[contenteditable="true"]')];
      let order = 0;
      allInputs.forEach(el => {
        const key = fieldKey(el);
        if (!key) return;
        const kind = detectKind(el);
        const q = el.closest ? el.closest('.q-field') : null;
        const isVisible = isReallyVisible(el) &&
          (!q || (q.style.display !== 'none' && q.style.visibility !== 'hidden'));
        const v = String(readValue(el) || '');
        if (!(key in fields) || v.trim() !== '') fields[key] = v;

        let label = textOf(el) ||
          (q && q.querySelector('.q-field__label') ? q.querySelector('.q-field__label').innerText : '') ||
          key;
        label = String(label).trim();
        if (label && /^(arrow_drop_down|expand_more|keyboard_arrow_down)\$/i.test(label)) label = key;

        let opts = [];
        if (el.tagName === 'SELECT') {
          opts = [...el.options]
            .map(o => ({value: String(o.value || o.textContent || '').trim(), label: String(o.textContent || '').trim()}))
            .filter(o => o.label);
        }

        schema[key] = {
          label: label,
          type: kind,
          required: !!el.required || String(el.getAttribute('aria-required') || '') === 'true',
          value: v,
          order: order++,
          visible: isVisible,
          options: opts,
        };
      });

      const b = window.__EMIS_APP_BRIDGE__;
      const schemaShape = {};
      Object.keys(schema).forEach(k => {
        const meta = Object.assign({}, schema[k]);
        delete meta.value;
        schemaShape[k] = meta;
      });
      const schemaSerial = JSON.stringify(schemaShape);
      if (schemaSerial !== b.schemaLast) {
        b.schemaLast = schemaSerial;
        if (Object.keys(schema).length) {
          send('schema', {fields: schema, url: location.href});
        }
      }
      b.lastSchema = schema;
      scheduleOptionCollection();
      const serial = JSON.stringify(fields);
      if (serial !== b.last) { b.last = serial; send('snapshot', {fields: fields, url: location.href}); }
    };

    const nativeSet = (el, value) => {
      try {
        const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
        if (setter) setter.call(el, String(value)); else el.value = String(value);
      } catch(e) {
        try { el.value = String(value); } catch(_) {}
      }
      try { el.dispatchEvent(new Event('input', {bubbles:true})); } catch(e) {}
      try { el.dispatchEvent(new Event('change', {bubbles:true})); } catch(e) {}
      try { el.dispatchEvent(new Event('blur', {bubbles:true})); } catch(e) {}
    };

    const sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms));

    const findField = (key) => {
      const wanted = norm(key);
      const aa = (aliases[key] || []).map(norm);
      const all = [...document.querySelectorAll('.q-field, input,textarea,select,[contenteditable="true"]')];
      for (const el of all) {
        const dynamicKey = norm(fieldKey(el));
        const cs = candidates(el);
        if (dynamicKey === wanted || cs.some(c => aa.includes(c))) {
          return el.classList?.contains('q-field') ? el : (el.closest('.q-field') || el);
        }
      }
      for (const el of all) {
        const cs = candidates(el);
        if (cs.some(c => aa.some(a => a.length >= 4 && (c === a || (c.includes(a) && !c.match(new RegExp('^' + a + '.'))))))) {
          return el.classList?.contains('q-field') ? el : (el.closest('.q-field') || el);
        }
      }
      return null;
    };

    // ===================== التقاط قوائم EMIS (القيمة الحقيقية أولاً) =====================
    // el.offsetParent يعود null لكل عنصر position:fixed (وقائمة Quasar .q-menu ثابتة الموضع)،
    // لذلك لا يصلح وحده كاختبار ظهور.
    const isShown = (el) => {
      if (!el) return false;
      try {
        if (el.offsetParent !== null) return true;
        if (el.getClientRects().length === 0) return false;
        const st = window.getComputedStyle(el);
        return st.display !== 'none' && st.visibility !== 'hidden';
      } catch(e) { return false; }
    };

    // على أجهزة الجوال يفتح Quasar قائمة الاختيار داخل dialog (.q-select__dialog) لا داخل .q-menu.
    const popupItemSelector = '.q-menu .q-item, .q-menu [role="option"], .q-select__dialog .q-item, .q-select__dialog [role="option"], [role="listbox"] .q-item, [role="listbox"] [role="option"]';

    const findPopup = (field) => {
      const inputs = [...field.querySelectorAll('input,[role="combobox"]')];
      for (const inp of inputs) {
        for (const a of ['aria-controls', 'aria-owns']) {
          const id = inp.getAttribute(a);
          if (!id) continue;
          const el = document.getElementById(id);
          if (el && isShown(el)) return el;
        }
      }
      const pool = [...document.querySelectorAll('.q-menu, .q-select__dialog, [role="listbox"]')].filter(m => {
        if (!isShown(m)) return false;
        const r = m.getBoundingClientRect();
        return r.width > 40 && r.height > 20;
      });
      return pool.length ? pool[pool.length - 1] : null;
    };

    // مكوّنات Vue لا تُكشف على DOM إلا في نسخة التطوير (أو عند تفعيل devtools للإنتاج)،
    // لذلك هذا المسار قد يعيد فارغاً على موقع الإنتاج؛ وعندها يُستعمل مسار DOM.
    const vueInstances = (field) => {
      const list = [];
      const seen = new Set();
      const roots = [field, ...field.querySelectorAll('*')];
      for (const node of roots) {
        let inst = node && (node.__vueParentComponent || (node.__vnode && node.__vnode.component) || (node._vnode && node._vnode.component));
        for (let depth = 0; inst && depth < 10 && !seen.has(inst); depth++) {
          seen.add(inst);
          list.push(inst);
          inst = inst.parent;
        }
      }
      return list;
    };

    const readVueOptions = (field) => {
      try {
        const insts = vueInstances(field);
        const rank = (i) => (i.type && /QSelect/i.test(String(i.type.name || ''))) ? 0 : 1;
        insts.sort((x, y) => rank(x) - rank(y));
        for (const inst of insts) {
          const props = inst.props || {};
          let raw = props.options;
          if (raw && !Array.isArray(raw) && Array.isArray(raw.value)) raw = raw.value;
          if (!Array.isArray(raw) || !raw.length) continue;
          const ov = props.optionValue;
          const ol = props.optionLabel;
          const pickBy = (o, spec, fallbacks) => {
            if (typeof spec === 'function') { try { return spec(o); } catch(e) {} }
            if (o && typeof o === 'object') {
              if (typeof spec === 'string' && o[spec] !== undefined && o[spec] !== null) return o[spec];
              for (const k of fallbacks) {
                if (o[k] !== undefined && o[k] !== null && String(o[k]).trim() !== '') return o[k];
              }
              return undefined;
            }
            return o;
          };
          const out = [];
          const seen = new Set();
          for (const o of raw) {
            if (o === null || o === undefined) continue;
            const value = pickBy(o, ov, ['value', 'id', 'code', 'shortName', 'name']);
            const label = pickBy(o, ol, ['label', 'displayName', 'name', 'text', 'shortName', 'value']);
            const v = String(value === null || value === undefined ? '' : value).trim();
            const l = String(label === null || label === undefined ? v : label).trim();
            if (!v || !l || seen.has(v)) continue;
            seen.add(v);
            out.push({value: v, label: l, _src: 'vue', _complete: true});
          }
          if (out.length) return out;
        }
      } catch(e) {}
      return [];
    };

    // مجموعات الاختيار (q-option-group: radio/checkbox) لا تحتوي q-select فلا تُلتقط بالنقر.
    const groupLabelOf = (g) => {
      const clean = (el) => {
        if (!el) return '';
        const c = el.cloneNode(true);
        c.querySelectorAll('input,.q-option-group,.q-radio,.q-checkbox,.q-toggle,i,svg,.q-icon,button').forEach(n => n.remove());
        return String(c.innerText || c.textContent || '').replace(/\\s+/g, ' ').trim();
      };
      let node = g;
      for (let depth = 0; node && depth < 4; depth++, node = node.parentElement) {
        let prev = node.previousElementSibling;
        for (let i = 0; prev && i < 3; i++, prev = prev.previousElementSibling) {
          const t = clean(prev);
          if (t && t.length <= 120) return t;
        }
        const own = node.querySelector(':scope > .q-field__label, :scope > label, :scope > .text-subtitle1, :scope > .text-subtitle2, :scope > .text-caption');
        const t2 = clean(own);
        if (t2) return t2;
      }
      return '';
    };

    const keyForLabel = (label) => {
      const c = norm(label);
      if (!c) return '';
      for (const k of Object.keys(aliases)) {
        if ((aliases[k] || []).map(norm).includes(c)) return k;
      }
      for (const k of sortedAliasKeys) {
        const aa = (aliases[k] || []).map(norm);
        if (aa.some(a => a.length >= 4 && (c === a || c.includes(a) || a.includes(c)))) return k;
      }
      return String(label || '').trim();
    };

    const readOptionGroups = () => {
      const result = {};
      try {
        document.querySelectorAll('.q-option-group').forEach(g => {
          if (!isShown(g)) return;
          const opts = [];
          const seen = new Set();
          g.querySelectorAll('.q-radio, .q-checkbox, .q-toggle').forEach(item => {
            const input = item.querySelector('input');
            const lab = item.querySelector('.q-radio__label, .q-checkbox__label, .q-toggle__label');
            const label = String((lab && (lab.innerText || lab.textContent)) || item.innerText || item.textContent || '').replace(/\\s+/g, ' ').trim();
            let value = input ? String(input.getAttribute('value') || '').trim() : '';
            if (!value || value === 'on') value = label;
            if (!label || !value || seen.has(value)) return;
            seen.add(value);
            opts.push({value: value, label: label, _src: 'group', _complete: true});
          });
          if (!opts.length) return;
          const key = keyForLabel(groupLabelOf(g));
          if (key && !result[key]) result[key] = opts;
        });
      } catch(e) {}
      return result;
    };

    const readQSelectOptions = async (key) => {
      const field = findField(key);
      if (!field) return [];
      try {
        // 1) كتالوج Quasar الكامل من خصائص Vue (قيمة حقيقية) إن كانت مكشوفة.
        const fromVue = readVueOptions(field);
        if (fromVue.length) return fromVue;

        // 2) فتح القائمة وقراءة عناصرها من DOM (قيمة = نص، ما لم تتوفر سمة قيمة).
        pressEscape(document);
        await sleep(120);
        field.scrollIntoView({block:'center', inline:'nearest'});
        await sleep(80);

        const targets = [
          field.querySelector('.q-field__control'),
          field.querySelector('.q-field__native'),
          field.querySelector('input'),
          field
        ].filter(Boolean);

        let popup = null;
        for (const target of targets) {
          try { target.click(); } catch(e) {}
          for (let attempt = 0; attempt < 10; attempt++) {
            await sleep(100);
            popup = findPopup(field);
            if (popup) break;
          }
          if (popup) break;
        }
        if (!popup) return [];

        const values = [];
        const seen = new Set();
        const collect = () => {
          popup.querySelectorAll('.q-item, [role="option"]').forEach(x => {
            const clone = x.cloneNode(true);
            clone.querySelectorAll('i,svg,.q-icon,[class*=icon],button').forEach(n => n.remove());
            const label = String(clone.innerText || clone.textContent || '').replace(/\\s+/g,' ').trim();
            if (!label || /^(اختر|select|search|arrow_drop_down|expand_more)\$/i.test(label)) return;
            let value = String(x.getAttribute('data-value') || x.getAttribute('data-id') || x.getAttribute('value') || '').trim();
            let src = value ? 'attr' : 'dom';
            if (!value) {
              let node = x;
              for (let depth = 0; depth < 5 && node && !value; depth++, node = node.parentElement) {
                const vnode = node.__vnode || node._vnode;
                const props = vnode && (vnode.props || (vnode.component && vnode.component.props));
                const item = props && (props.item || props.opt || props.option || props);
                if (item && typeof item === 'object') {
                  const candidate = item.value ?? item.id ?? item.code ?? item.shortName;
                  if (candidate !== undefined && candidate !== null) { value = String(candidate).trim(); src = 'vue'; }
                }
              }
            }
            if (!value) value = label;
            if (!seen.has(value)) { seen.add(value); values.push({value: value, label: label, _src: src}); }
          });
        };
        collect();

        const scrollers = [popup, ...popup.querySelectorAll('.q-virtual-scroll, .scroll, .q-scrollarea__container')];
        const scroller = scrollers.find(sc => sc.scrollHeight > sc.clientHeight + 4) || null;
        let reachedEnd = true;
        if (scroller) {
          reachedEnd = false;
          let unchanged = 0;
          for (let i = 0; i < 120 && unchanged < 4; i++) {
            const before = seen.size;
            scroller.scrollTop = Math.min(scroller.scrollTop + scroller.clientHeight * 0.8, scroller.scrollHeight);
            await sleep(90);
            collect();
            unchanged = seen.size === before ? unchanged + 1 : 0;
            if (scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 2 && unchanged >= 2) { reachedEnd = true; break; }
          }
        }
        // القائمة تُعدّ "كاملة" فقط إذا وصلنا لنهايتها؛ عندها تحدد العضوية في التطبيق.
        values.forEach(v => { v._complete = reachedEnd; });

        pressEscape(document);
        await sleep(150);
        pressEscape(document.activeElement);
        await sleep(100);
        return values;
      } catch (e) {
        try { pressEscape(document); } catch(_) {}
        return [];
      }
    };

    const collectOptions = async (keys) => {
      const b = window.__EMIS_APP_BRIDGE__;
      let waited = 0;
      while (b.collecting && waited < 8000) { await sleep(150); waited += 150; }
      b.collecting = true;
      const out = {};
      try {
        const groups = readOptionGroups();
        for (const key of keys) {
          let values = groups[key] || [];
          if (!values.length) values = await readQSelectOptions(key);
          if (values.length) {
            out[key] = values;
            b.optionsCollected[key] = values.length;
          }
        }
      } finally {
        b.collecting = false;
      }
      if (Object.keys(out).length) {
        send('options', {options: out});
        send('status', {message: 'تم جلب خيارات EMIS: ' + Object.keys(out).map(k => k + '(' + out[k].length + ')').join(', ')});
      } else {
        send('status', {message: 'لم يعثر جسر EMIS على خيارات ظاهرة للحقول: ' + keys.join(', ')});
      }
      return out;
    };

    // إعادة محاولة متدرجة بدل محاولات ثلاث لمرة واحدة: القوائم المعتمدة على قوائم أخرى
    // أو المحمّلة كسولاً تظهر بعد أن يكون المسح الأول قد استهلك محاولاته.
    let optTimer = null;
    const scheduleOptionCollection = () => {
      if (optTimer) return;
      optTimer = setTimeout(async () => {
        optTimer = null;
        const b = window.__EMIS_APP_BRIDGE__;
        if (b.collecting) return;
        if (Date.now() - (b.lastPush || 0) < 4000) { scheduleOptionCollection(); return; }
        const groups = readOptionGroups();
        const gs = JSON.stringify(groups);
        if (gs !== b.groupsLast && Object.keys(groups).length) {
          b.groupsLast = gs;
          send('options', {options: groups});
        }
        const schema = b.lastSchema || {};
        const keys = Object.keys(schema).filter(k => {
          const m = schema[k];
          if (!m || m.type !== 'select' || !m.visible) return false;
          if ((m.options || []).length > 0) return false;
          if (b.optionsCollected[k]) return false;
          return (b.triedEmptySelects[k] || 0) < 8;
        }).slice(0, 4);
        if (!keys.length) return;
        keys.forEach(k => { b.triedEmptySelects[k] = (b.triedEmptySelects[k] || 0) + 1; });
        await collectOptions(keys);
      }, 350);
    };
    // ====================================================================================

    window.__EMIS_APP_BRIDGE__.collectOptions = (keys) => collectOptions(keys || []);
    window.__EMIS_APP_BRIDGE__.scanNow = () => scan();

    window.__EMIS_APP_BRIDGE__.setFields = (values) => {
      window.__EMIS_APP_BRIDGE__.lastPush = Date.now();
      const vals = values || {};
      for (const [key, value] of Object.entries(vals)) {
        const best = findField(key);
        if (!best) continue;
        try {
          const qfield = best.closest ? best.closest('.q-field') : null;
          const qnative = qfield ? qfield.querySelector('.q-field__native') : null;
          if (qfield && qnative && qfield.classList.contains('q-select')) {
            const rawWanted = String(value ?? '');
            const multiple = qfield.classList.contains('q-select--multiple');
            const wantedValues = multiple
              ? rawWanted.split(',').map(x => norm(x)).filter(Boolean)
              : [norm(rawWanted)];
            const currentValues = multiple
              ? [...qfield.querySelectorAll('.q-chip__content, .q-chip')]
                  .map(x => norm(x.innerText || x.textContent || '')).filter(Boolean)
              : [norm(qnative.value || '')];
            if (wantedValues.join('|') === currentValues.join('|')) continue;
            qfield.scrollIntoView({block:'center', inline:'nearest'});
            (qfield.querySelector('.q-field__control') || qnative || qfield).click();
            setTimeout(() => {
              const choose = (wanted) => {
                const items = [...document.querySelectorAll(popupItemSelector)];
                const item = items.find(o => {
                  const text = norm(o.innerText || o.textContent || '');
                  const attrs = ['data-value','data-id','value','aria-label'].map(a => norm(o.getAttribute(a) || ''));
                  return text === wanted || (wanted.length >= 2 && text.startsWith(wanted)) || attrs.includes(wanted);
                });
                if (item) item.click();
              };
              if (multiple) {
                wantedValues.forEach((wanted, index) => setTimeout(() => choose(wanted), index * 180));
                setTimeout(() => pressEscape(document), wantedValues.length * 180 + 160);
              } else {
                choose(wantedValues[0] || '');
                setTimeout(() => pressEscape(document), 180);
              }
            }, 120);
          } else if (best.tagName === 'SELECT') {
            const wanted = String(value ?? '');
            const option = [...best.options].find(o =>
              String(o.value) === wanted || norm(o.textContent) === norm(wanted)
            );
            if (option && (best.value !== option.value || norm(best.options[best.selectedIndex]?.textContent) !== norm(value))) {
              best.value = option.value;
              best.dispatchEvent(new Event('input', {bubbles:true}));
              best.dispatchEvent(new Event('change', {bubbles:true}));
            }
          } else if (best.isContentEditable) {
            if (norm(best.textContent) === norm(String(value ?? ''))) continue;
            best.textContent = String(value ?? '');
            best.dispatchEvent(new InputEvent('input', {bubbles:true, inputType:'insertText', data: String(value ?? '')}));
          } else {
            if (String(best.value ?? '') === String(value ?? '')) continue;
            nativeSet(best, value ?? '');
          }
        } catch(e) {}
      }
      scan();
      setTimeout(scan, 200);
      setTimeout(scan, 500);
      setTimeout(scan, 1000);
      setTimeout(scan, 2000);
      setTimeout(scan, 3500);
    };

    window.__EMIS_APP_BRIDGE__.focusField = (key) => {
      const best = findField(key);
      if (!best) return false;
      try {
        best.scrollIntoView({block:'center', inline:'nearest'});
        best.focus();
        best.click();
        send('focus', {field: key});
        return true;
      } catch(e) { return false; }
    };

    const clickText = (patterns) => {
      const els = [...document.querySelectorAll('button,a,[role="button"],.q-btn,.q-item')];
      for (const el of els) {
        const t = norm(el.innerText || el.getAttribute('aria-label') || '');
        if (patterns.some(p => p.test(t))) {
          try { el.click(); return true; } catch(e) {}
        }
      }
      return false;
    };

    const openTarget = () => {
      const b = window.__EMIS_APP_BRIDGE__;
      if (b.opened) return true;
      const id = norm(b.recordId);
      if (!id) return false;
      const currentPath = norm(location.pathname);
      if (currentPath.includes('/management/edit/') && currentPath.includes(id)) {
        b.opened = true;
        send('status', {message: 'تم تحميل نموذج تعديل المعلم من EMIS'});
        return true;
      }
      return false;
    };

    let scanTimer = null;
    const scheduleScan = (delay) => {
      if (scanTimer) clearTimeout(scanTimer);
      scanTimer = setTimeout(() => { scanTimer = null; scan(); }, delay || 100);
    };

    document.addEventListener('input', scan, true);
    document.addEventListener('change', scan, true);
    document.addEventListener('blur', () => scheduleScan(80), true);
    document.addEventListener('focusin', (e) => {
      const key = fieldKey(e.target);
      if (key) send('focus', {field: key});
    }, true);

    const findFormContainers = () => {
      const candidates = document.querySelectorAll('.q-page, .q-card, form, .q-form, [class*="form-container"]');
      const containers = [];
      candidates.forEach(c => {
        if (c.offsetParent !== null && c.getBoundingClientRect().height > 100) {
          containers.push(c);
        }
      });
      return containers.length ? containers : [document.body];
    };

    const observers = [];
    const startObservers = () => {
      observers.forEach(o => { try { o.disconnect(); } catch(e) {} });
      observers.length = 0;
      const containers = findFormContainers();
      containers.forEach(container => {
        const obs = new MutationObserver(mutations => {
          let relevant = false;
          for (const m of mutations) {
            if (m.type === 'childList') {
              for (const node of m.addedNodes) {
                if (node.nodeType === 1) {
                  if (node.matches?.('.q-field, input, select, textarea') ||
                      node.querySelector?.('.q-field, input, select, textarea')) {
                    relevant = true;
                    break;
                  }
                }
              }
            } else if (m.type === 'attributes') {
              const target = m.target;
              if (target.matches?.('.q-field, .q-field__native, input, select, textarea') ||
                  target.closest?.('.q-field')) {
                relevant = true;
              }
            }
            if (relevant) break;
          }
          if (relevant) scheduleScan(100);
        });
        obs.observe(container, {
          subtree: true,
          childList: true,
          attributes: true,
          attributeFilter: ['class', 'aria-expanded', 'aria-hidden', 'style', 'disabled', 'readonly', 'value']
        });
        observers.push(obs);
      });
    };

    const openAndScan = () => {
      const b = window.__EMIS_APP_BRIDGE__;
      const opened = openTarget();
      if (opened && !b.opened) b.opened = true;
      if (opened) startObservers();
      scan();
    };

    let tries = 0;
    const bootstrapTimer = setInterval(() => {
      tries++;
      openAndScan();
      if (window.__EMIS_APP_BRIDGE__.opened || tries > 30) {
        clearInterval(bootstrapTimer);
        setInterval(() => {
          if (document.hidden) return;
          scan();
        }, 2000);
      }
    }, 400);

    let lastHref = location.href;
    setInterval(() => {
      if (location.href !== lastHref) {
        lastHref = location.href;
        window.__EMIS_APP_BRIDGE__.opened = false;
        window.__EMIS_APP_BRIDGE__.last = '';
        window.__EMIS_APP_BRIDGE__.schemaLast = '';
        scheduleScan(500);
      }
    }, 800);

    scan();
    send('status', {message: 'جسر المزامنة الذكي جاهز'});
  } catch(e) {
    try {
      EmisSyncChannel.postMessage(JSON.stringify({
        type: 'status', message: 'خطأ في جسر المزامنة: ' + e
      }));
    } catch(_) {}
  }
})();''';

    try {
      if (_isWindows) {
        await _runJavaScript(r'''(function(){
          if (!window.EmisSyncChannel && window.chrome && window.chrome.webview) {
            window.EmisSyncChannel = {
              postMessage: function(message) {
                try { window.chrome.webview.postMessage(String(message)); } catch (_) {}
              }
            };
          }
        })();''');
      }
      await _runJavaScript(js);
      final installed = await _runJavaScriptReturningResult(
        'Boolean(window.__EMIS_APP_BRIDGE__ && window.__EMIS_APP_BRIDGE__.scanNow)',
      );
      _ready = '$installed'.toLowerCase().contains('true');
    } catch (_) {
      _ready = false;
    }
  }

  Future<void> refreshOptions(List<String> keys) async {
    if (!_ready || keys.isEmpty) return;
    final encoded = jsonEncode(keys);
    final js = '''
(function(){
  try {
    if(window.__EMIS_APP_BRIDGE__ && window.__EMIS_APP_BRIDGE__.collectOptions) {
      var keys = $encoded;
      for (var i = 0; i < keys.length; i++) {
        window.__EMIS_APP_BRIDGE__.triedEmptySelects[keys[i]] = 0;
      }
      window.__EMIS_APP_BRIDGE__.collectOptions(keys);
    }
  } catch(e) {}
})();''';
    try { await _runJavaScript(js); } catch (_) {}
  }

  /// يلتقط قوائم كل الحقول المنسدلة الظاهرة التي لم تُلتقط قوائمها بعد (أو أُعيد تحميلها).
  Future<void> refreshAllOptions() async {
    if (!_ready) return;
    const js = '''
(function(){
  try {
    var b = window.__EMIS_APP_BRIDGE__;
    if (!b || !b.collectOptions) return;
    var keys = Object.keys(b.lastSchema || {}).filter(function(k){
      var m = b.lastSchema[k];
      return m && m.type === 'select' && m.visible;
    });
    keys.forEach(function(k){ b.triedEmptySelects[k] = 0; });
    if (keys.length) b.collectOptions(keys);
  } catch(e) {}
})();''';
    try { await _runJavaScript(js); } catch (_) {}
  }

  Future<void> refreshSchema() async {
    if (!_ready) return;
    try {
      await _runJavaScript('''(function(){try{if(window.__EMIS_APP_BRIDGE__ && window.__EMIS_APP_BRIDGE__.scanNow) window.__EMIS_APP_BRIDGE__.scanNow();}catch(e){}})();''');
    } catch (_) {}
  }

  Future<void> pushValues(Map<String, String> values) async {
    if (!_ready || values.isEmpty) return;
    final encoded = jsonEncode(values);
    final js = '''
(function(){
  try {
    if(window.__EMIS_APP_BRIDGE__ && window.__EMIS_APP_BRIDGE__.setFields){
      window.__EMIS_APP_BRIDGE__.setFields($encoded);
    }
  } catch(e) {}
})();''';
    try {
      await _runJavaScript(js);
      _hasPushedValues = true;
      _firstPushAt ??= DateTime.now();
    } catch (_) {}
  }

  Future<void> focusField(String key) async {
    if (!_ready || key.trim().isEmpty) return;
    final js = '''
(function(){
  try {
    if(window.__EMIS_APP_BRIDGE__ && window.__EMIS_APP_BRIDGE__.focusField){
      window.__EMIS_APP_BRIDGE__.focusField(${jsonEncode(key)});
    }
  } catch(e) {}
})();''';
    try {
      await _runJavaScript(js);
    } catch (_) {}
  }

  @override
  void dispose() {
    _windowsBridgeRetry?.cancel();
    final messageSubscription = _windowsMessageSubscription;
    if (messageSubscription != null) {
      unawaited(messageSubscription.cancel());
    }
    final web = _windowsController;
    if (web != null) {
      unawaited(web.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Opacity(
        opacity: 0.01,
        child: SizedBox(
          width: 390,
          height: 720,
          child: _isWindows
              ? (_windowsController != null && _windowsController!.value.isInitialized
                  ? win_wv.Webview(_windowsController!)
                  : const SizedBox.shrink())
              : (_mobileController != null
                  ? WebViewWidget(controller: _mobileController!)
                  : const SizedBox.shrink()),
        ),
      ),
    );
  }
}
