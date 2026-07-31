/* Homelab Drive — public share lightbox/slideshow
 * Standalone counterpart to app.js's DriveUI lightbox, for anonymous /s/:token
 * pages. No htmx/jQuery/jsTree dependency — the image list is read once from
 * the static server-rendered DOM (single-file preview or the directory-share
 * file table), so there's no fileListChanged-style cache invalidation to do:
 * an anonymous, read-only page can't have files added/removed/renamed under it.
 */
const PublicLightbox = (() => {
  const TOKEN      = document.body.dataset.token || '';
  const SHARE_TYPE = document.body.dataset.shareType || '';

  let _lbImages = [];   // [{uuid, name}]
  let _lbIndex  = -1;
  let _lbTimer  = null; // slideshow setInterval handle
  let _lbSeconds = 4;   // current interval; 0 = off

  function _images() {
    if (SHARE_TYPE === 'dir') {
      return [...document.querySelectorAll('.pub-dir-table tr[data-uuid]')]
        .filter(row => /^image\//.test(row.dataset.mime || ''))
        .map(row => ({ uuid: row.dataset.uuid, name: row.dataset.name || '' }));
    }
    // Single-file share: one image at most.
    const preview = document.querySelector('.pub-file-preview');
    if (!preview) return [];
    return [{ uuid: preview.dataset.uuid || '0', name: preview.dataset.name || '' }];
  }

  function _slideUrl(uuid) {
    return SHARE_TYPE === 'dir'
      ? `/s/${TOKEN}/files/${uuid}/slide-show-image`
      : `/s/${TOKEN}/slide-show-image`;
  }

  function _downloadUrl(uuid) {
    return SHARE_TYPE === 'dir'
      ? `/s/${TOKEN}/files/${uuid}/download`
      : `/s/${TOKEN}/download`;
  }

  // Session-scoped image cache: uuid -> objectURL. Map insertion order
  // doubles as LRU order (re-inserting on access = MRU).
  const LB_CACHE_MAX = 15;
  const _lbCache = new Map();
  const _lbInflight = new Map();

  function _lbCacheEvictOldest() {
    while (_lbCache.size > LB_CACHE_MAX) {
      const oldestUuid = _lbCache.keys().next().value;
      URL.revokeObjectURL(_lbCache.get(oldestUuid));
      _lbCache.delete(oldestUuid);
    }
  }

  function _prefetchImage(uuid) {
    if (_lbCache.has(uuid) || _lbInflight.has(uuid)) return;
    const p = fetch(_slideUrl(uuid), { credentials: 'same-origin' })
      .then(r => r.ok ? r : fetch(_downloadUrl(uuid), { credentials: 'same-origin' }))
      .then(r => r.ok ? r.blob() : Promise.reject())
      .then(blob => {
        _lbCache.set(uuid, URL.createObjectURL(blob));
        _lbCacheEvictOldest();
      })
      .catch(() => {})
      .finally(() => _lbInflight.delete(uuid));
    _lbInflight.set(uuid, p);
  }

  function _prefetchNeighbors() {
    if (_lbImages.length <= 1) return;
    [1, 2, -1].forEach(offset => {
      const target = _lbImages[(_lbIndex + offset + _lbImages.length) % _lbImages.length];
      if (target) _prefetchImage(target.uuid);
    });
  }

  function open(uuid) {
    _lbImages = _images();
    _lbIndex = _lbImages.findIndex(f => f.uuid === uuid);
    if (_lbIndex < 0) return false;
    _showImage();
    document.getElementById('lightbox')?.classList.remove('hidden');
    _startSlideshow();
    return false;
  }

  function _showImage() {
    const img = _lbImages[_lbIndex];
    if (!img) return;
    const slideUrl    = _slideUrl(img.uuid);
    const downloadUrl = _downloadUrl(img.uuid);
    const image    = document.getElementById('lightbox-image');
    const download = document.getElementById('lightbox-download');
    const caption  = document.getElementById('lightbox-caption');
    const counter  = document.getElementById('lightbox-counter');

    if (image) {
      const cachedUrl = _lbCache.get(img.uuid);
      if (cachedUrl) {
        _lbCache.delete(img.uuid);
        _lbCache.set(img.uuid, cachedUrl);
        image.onerror = null;
        image.src = cachedUrl;
      } else {
        image.onerror = () => { image.onerror = null; image.src = downloadUrl; };
        image.src = slideUrl;
        _prefetchImage(img.uuid);
      }
    }
    if (download) { download.href = downloadUrl; download.download = img.name; }
    if (caption)  caption.textContent = img.name;
    if (counter)  counter.textContent = `${_lbIndex + 1} / ${_lbImages.length}`;

    const multi = _lbImages.length > 1;
    document.querySelectorAll('.lightbox-nav').forEach(b => b.classList.toggle('hidden', !multi));
    const playBtn = document.getElementById('lightbox-play');
    if (playBtn) playBtn.disabled = !multi;
    document.querySelectorAll('.lightbox-speed button').forEach(b => b.disabled = !multi);

    _prefetchNeighbors();
  }

  function close() {
    _stopSlideshow();
    if (document.fullscreenElement) document.exitFullscreen?.();
    document.getElementById('lightbox')?.classList.add('hidden');
    const image = document.getElementById('lightbox-image');
    if (image) image.src = '';
  }

  function next() {
    if (!_lbImages.length) return;
    _lbIndex = (_lbIndex + 1) % _lbImages.length;
    _showImage();
    _restartSlideshowIfRunning();
  }

  function prev() {
    if (!_lbImages.length) return;
    _lbIndex = (_lbIndex - 1 + _lbImages.length) % _lbImages.length;
    _showImage();
    _restartSlideshowIfRunning();
  }

  function _updatePlayGlyph() {
    const playBtn = document.getElementById('lightbox-play');
    if (playBtn) playBtn.textContent = _lbTimer ? '⏸' : '⏵';
  }

  function toggleSlideshow() {
    if (_lbTimer) _stopSlideshow();
    else _startSlideshow();
  }

  function _startSlideshow() {
    if (_lbSeconds <= 0 || _lbImages.length <= 1) return;
    _lbTimer = setInterval(next, _lbSeconds * 1000);
    _updatePlayGlyph();
  }

  function _stopSlideshow() {
    clearInterval(_lbTimer);
    _lbTimer = null;
    _updatePlayGlyph();
  }

  function _restartSlideshowIfRunning() {
    if (_lbTimer) { _stopSlideshow(); _startSlideshow(); }
  }

  function setSlideshowInterval(secs) {
    _lbSeconds = secs;
    document.querySelectorAll('.lightbox-speed button').forEach(b => {
      b.classList.toggle('active', +b.dataset.secs === secs);
    });
    if (secs === 0) _stopSlideshow();
    else _restartSlideshowIfRunning();
  }

  function downloadCurrent() {
    document.getElementById('lightbox-download')?.click();
  }

  function toggleFullscreen() {
    const el = document.querySelector('.lightbox-content');
    if (!el) return;
    if (!document.fullscreenElement) el.requestFullscreen?.();
    else document.exitFullscreen?.();
  }

  document.getElementById('lightbox-image')?.addEventListener('click', (e) => {
    if (!window.matchMedia('(hover: hover)').matches) {
      e.currentTarget.closest('.lightbox-content')?.classList.toggle('controls-visible');
    }
  });

  document.addEventListener('keydown', (e) => {
    const lb = document.getElementById('lightbox');
    if (!lb || lb.classList.contains('hidden')) return;
    if (e.target.matches('input, textarea')) return;
    switch (e.key) {
      case 'Escape': close(); break;
      case ' ': case 'p': case 'P': e.preventDefault(); toggleSlideshow(); break;
      case 'd': case 'D': downloadCurrent(); break;
      case 'ArrowLeft':  prev(); break;
      case 'ArrowRight': next(); break;
      case 'Home': _lbIndex = 0; _showImage(); _restartSlideshowIfRunning(); break;
      case 'End':  _lbIndex = _lbImages.length - 1; _showImage(); _restartSlideshowIfRunning(); break;
      case 'f': case 'F': toggleFullscreen(); break;
      default:
        if (e.key >= '1' && e.key <= '9') setSlideshowInterval(+e.key);
        else if (e.key === '0') setSlideshowInterval(0);
    }
  });

  return {
    open,
    close,
    prev,
    next,
    toggleSlideshow,
    setSlideshowInterval,
    toggleFullscreen,
  };
})();
