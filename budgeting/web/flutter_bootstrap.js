{{flutter_js}}
{{flutter_build_config}}

window.addEventListener('flutter-first-frame', function () {
  document.getElementById('loading')?.remove();
}, { once: true });

// Financial responses and authentication must never enter an offline cache.
_flutter.loader.load();
