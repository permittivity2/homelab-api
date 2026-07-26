/* Homelab Drive Web UI */
const DriveUI = (() => {
  let currentDirId = null;

  // --- jsTree: sidebar folder tree ---

  function initTree(activeDirId) {
    $('#dir-tree').jstree({
      core: {
        data: { url: '/drive/tree.json' },
        check_callback: true,
        themes: { dots: true, icons: true },
      },
      plugins: ['dnd', 'contextmenu', 'wholerow'],
      dnd: { copy: false, touch: true },
      contextmenu: {
        items: function(node) {
          return {
            rename: {
              label: 'Rename',
              action: function() { renameDirById(parseInt(node.id, 10), node.text); }
            },
            remove: {
              label: 'Delete',
              separator_before: true,
              action: function() { deleteDirById(parseInt(node.id, 10), node.text); }
            }
          };
        }
      }
    });

    // Navigate on node click
    $('#dir-tree').on('select_node.jstree', function(e, data) {
      const id = parseInt(data.node.id, 10);
      if (id !== currentDirId) navigate(id);
    });

    // Drag-to-reparent: PATCH parent_id
    $('#dir-tree').on('move_node.jstree', function(e, data) {
      const nodeId   = data.node.id;
      const parentId = data.parent === '#' ? '' : data.parent;
      htmx.ajax('PATCH', `/drive/directories/${nodeId}`, {
        target: 'body', swap: 'none',
        values: { parent_id: parentId }
      });
    });

    // Highlight active node after tree finishes loading
    $('#dir-tree').on('ready.jstree', function() {
      setTreeActive(activeDirId);
    });

    // Accept file-row drops onto jsTree sidebar nodes
    const dirTreeEl = document.getElementById('dir-tree');
    if (dirTreeEl) {
      dirTreeEl.addEventListener('dragover', (e) => {
        if (!Array.from(e.dataTransfer.types).includes('application/x-file-id')) return;
        e.preventDefault();
        e.dataTransfer.dropEffect = 'move';
        const node = e.target.closest('li.jstree-node');
        if (node) {
          document.querySelectorAll('#dir-tree li.dir-drop-hover').forEach(n => n.classList.remove('dir-drop-hover'));
          node.classList.add('dir-drop-hover');
        }
      });
      dirTreeEl.addEventListener('dragleave', (e) => {
        if (!dirTreeEl.contains(e.relatedTarget)) {
          document.querySelectorAll('#dir-tree li.dir-drop-hover').forEach(n => n.classList.remove('dir-drop-hover'));
        }
      });
      dirTreeEl.addEventListener('drop', (e) => {
        e.preventDefault();
        document.querySelectorAll('#dir-tree li.dir-drop-hover').forEach(n => n.classList.remove('dir-drop-hover'));
        const fileId = e.dataTransfer.getData('application/x-file-id');
        if (!fileId) return;
        const node = e.target.closest('li.jstree-node');
        if (node) moveFileToDirId(fileId, node.id);
      });
    }
  }

  function setTreeActive(dirId) {
    const inst = $('#dir-tree').jstree(true);
    if (!inst) return;
    inst.deselect_all(true);
    if (dirId == null) return;
    const id = String(dirId);
    const node = inst.get_node(id);
    if (!node) return;
    // Open all ancestors so the active node is visible
    let cur = node;
    while (cur && cur.parent && cur.parent !== '#') {
      inst.open_node(cur.parent, false, false);
      cur = inst.get_node(cur.parent);
    }
    inst.select_node(id, true);
  }

  // --- File drag-to-folder ---

  function fileDragStart(e, el) {
    e.dataTransfer.setData('application/x-file-id', el.dataset.id);
    e.dataTransfer.setData('text/plain', el.querySelector('.file-name')?.textContent.trim() ?? '');
    e.dataTransfer.effectAllowed = 'move';
    el.classList.add('dragging');
  }

  function fileDragEnd(e, el) {
    el.classList.remove('dragging');
    document.querySelectorAll('.dir-row.drag-over-dir').forEach(r => r.classList.remove('drag-over-dir'));
    document.querySelectorAll('#dir-tree li.dir-drop-hover').forEach(n => n.classList.remove('dir-drop-hover'));
  }

  function dirDragOver(e, el) {
    if (!Array.from(e.dataTransfer.types).includes('application/x-file-id')) return;
    e.preventDefault();
    e.stopPropagation();
    e.dataTransfer.dropEffect = 'move';
    el.classList.add('drag-over-dir');
  }

  function dirDragLeave(e, el) {
    if (!el.contains(e.relatedTarget)) el.classList.remove('drag-over-dir');
  }

  function dirDrop(e, el) {
    e.preventDefault();
    e.stopPropagation();
    el.classList.remove('drag-over-dir');
    const fileId = e.dataTransfer.getData('application/x-file-id');
    if (!fileId) return;
    moveFileToDirId(fileId, el.dataset.id);
  }

  function moveFileToDirId(fileId, dirId) {
    // dirId null/undefined = move to root; empty string signals root to the BFF
    const dir_id = (dirId != null) ? String(dirId) : '';
    htmx.ajax('PATCH', `/drive/files/${fileId}`, {
      target: 'body', swap: 'none',
      values: { dir_id }
    }).then(() => htmx.trigger(document.body, 'fileListChanged'));
  }

  function homeDragOver(e, el) {
    if (!Array.from(e.dataTransfer.types).includes('application/x-file-id')) return;
    e.preventDefault();
    e.stopPropagation();
    e.dataTransfer.dropEffect = 'move';
    el.classList.add('drag-over-dir');
  }

  function homeDragLeave(e, el) {
    if (!el.contains(e.relatedTarget)) el.classList.remove('drag-over-dir');
  }

  function homeDrop(e, el) {
    e.preventDefault();
    e.stopPropagation();
    el.classList.remove('drag-over-dir');
    const fileId = e.dataTransfer.getData('application/x-file-id');
    if (!fileId) return;
    moveFileToDirId(fileId, null);  // null = root
  }

  // Refresh jsTree when folder CRUD operations send HX-Trigger: treeChanged
  document.body.addEventListener('treeChanged', function() {
    const inst = $('#dir-tree').jstree(true);
    if (inst) inst.refresh();
  });

  // --- Navigation ---

  // URL is the single source of truth for the current directory.
  // navigate() always calls history.pushState before any async work, so
  // the URL is always up-to-date when hx-vals or upload code reads it.
  function _currentDir() {
    return parseInt(new URLSearchParams(location.search).get('dir_id') || '', 10) || null;
  }

  function toggleSidebar() {
    document.querySelector('.sidebar')?.classList.toggle('sidebar-open');
  }

  function closeSidebar() {
    document.querySelector('.sidebar')?.classList.remove('sidebar-open');
  }

  function navigate(dirId) {
    currentDirId = dirId;
    const browsePath = dirId != null ? `/drive?dir_id=${dirId}` : '/drive';

    // If the file browser isn't in the DOM (e.g. Trash page), do a full page nav
    if (!document.getElementById('file-tbody')) {
      safeNavigate(browsePath);
      return;
    }

    closeSidebar();  // close sidebar drawer on mobile after picking a folder
    clearSelection();  // reset checkboxes whenever we change folder
    history.pushState({ dirId }, '', browsePath);  // update URL first — hx-vals reads from here
    _updateEmptyTrashBtn();
    const url = dirId != null ? `/drive/files?dir_id=${dirId}` : '/drive/files';
    htmx.ajax('GET', url, { target: '#file-tbody', swap: 'innerHTML' });
    setTreeActive(dirId);
  }

  window.addEventListener('popstate', (e) => {
    if (location.hash) {
      history.replaceState(e.state, '', location.pathname + location.search);
      return;
    }
    const dirId = e.state?.dirId ?? null;
    currentDirId = dirId;
    clearSelection();
    const url = dirId != null ? `/drive/files?dir_id=${dirId}` : '/drive/files';
    htmx.ajax('GET', url, { target: '#file-tbody', swap: 'innerHTML' });
    setTreeActive(dirId);
  });

  // --- Upload via XHR (drag-and-drop and file picker) ---
  function _fmtMB(bytes) {
    if (bytes >= 1073741824) return (bytes / 1073741824).toFixed(1) + ' GB';
    if (bytes >= 1048576)    return (bytes / 1048576).toFixed(1) + ' MB';
    if (bytes >= 1024)       return (bytes / 1024).toFixed(0) + ' KB';
    return bytes + ' B';
  }

  // Global upload queue tracker — spans multiple uploadFiles() batches
  const _uploadQueue = { total: 0, done: 0 };

  function _updateUploadIndicator() {
    const indicator = document.getElementById('upload-indicator');
    const label     = document.getElementById('upload-indicator-label');
    const active    = document.querySelectorAll('#upload-progress .upload-item.uploading').length;
    if (!indicator) return;
    if (active > 0) {
      indicator.classList.remove('hidden');
      const remaining = _uploadQueue.total - _uploadQueue.done;
      if (label) label.textContent = remaining > active
          ? `Uploading ${active} of ${remaining}`
          : (active === 1 ? 'Uploading' : `Uploading (${active})`);
    }
  }

  function toggleUploadPanel() {
    document.getElementById('upload-panel')?.classList.toggle('hidden');
  }

  function uploadFiles(files) {
    const progress  = document.getElementById('upload-progress');
    const indicator = document.getElementById('upload-indicator');
    // Only clear if nothing is currently uploading — preserve in-progress rows
    if (!progress.querySelector('.upload-item.uploading')) progress.innerHTML = '';
    indicator?.classList.remove('hidden');
    document.getElementById('upload-panel')?.classList.remove('hidden');

    const queue = Array.from(files);
    const uploadDirId = _currentDir();  // capture once at queue time — navigation must not change this
    console.log('[upload] queued', queue.length, 'files for dir_id=', uploadDirId);
    const concurrency = 4;
    let active = 0;
    let index = 0;
    _uploadQueue.total += queue.length;

    // Pre-create all rows as "Queued" so every file is visible immediately
    const items = queue.map(file => {
      const item = document.createElement('div');
      item.className = 'upload-item queued';
      item.innerHTML = `<span class="upload-filename">${escHtml(file.name)}</span>
                        <span class="upload-bar-wrap"><span class="upload-bar" style="width:0%"></span></span>
                        <span class="upload-pct upload-queued-label">Queued — ${_fmtMB(file.size)}</span>`;
      progress.appendChild(item);
      return item;
    });

    function next() {
      while (active < concurrency && index < queue.length) {
        uploadOne(queue[index], items[index]);
        index++;
        active++;
      }
    }

    function uploadOne(file, item) {
      item.className = 'upload-item uploading';
      const totalFmt = _fmtMB(file.size);
      item.innerHTML = `<span class="upload-filename">${escHtml(file.name)}</span>
                        <span class="upload-bar-wrap"><span class="upload-bar" style="width:0%"></span></span>
                        <span class="upload-pct">0 B / ${totalFmt}</span>`;

      const bar = item.querySelector('.upload-bar');
      const pct = item.querySelector('.upload-pct');

      const fd = new FormData();
      fd.append('file', file);
      if (uploadDirId != null) fd.append('dir_id', uploadDirId);
      console.log('[upload] starting', file.name, 'dir_id=', uploadDirId, 'current url dir=', _currentDir());

      const xhr = new XMLHttpRequest();
      xhr.upload.onprogress = (e) => {
        if (e.lengthComputable) {
          const p = Math.round(e.loaded / e.total * 100);
          bar.style.width = p + '%';
          pct.textContent = `${_fmtMB(e.loaded)} / ${_fmtMB(e.total)} (${p}%)`;
        }
      };
      xhr.onload = () => {
        active--;
        item.classList.remove('uploading');
        if (xhr.status >= 200 && xhr.status < 300) {
          item.classList.add('upload-ok');
          pct.textContent = 'Done ✓';
          htmx.trigger(document.body, 'fileUploaded');  // quota bar always refreshes
          // Only reload the file list if we're still viewing the upload destination
          if (_currentDir() === uploadDirId) {
            const url = uploadDirId != null ? `/drive/files?dir_id=${uploadDirId}` : '/drive/files';
            htmx.ajax('GET', url, { target: '#file-tbody', swap: 'innerHTML' });
          }
        } else {
          item.classList.add('upload-fail');
          pct.textContent = 'Failed ✗';
        }
        _uploadQueue.done++;
        if (_uploadQueue.done >= _uploadQueue.total) { _uploadQueue.total = 0; _uploadQueue.done = 0; }
        _updateUploadIndicator();
        next();
        // Only hide panel when ALL batches are done (check global DOM state, not per-batch counter)
        if (!document.querySelector('#upload-progress .upload-item.uploading')) {
          const lbl = document.getElementById('upload-indicator-label');
          if (lbl) lbl.textContent = 'Uploads done';
          setTimeout(() => {
            if (!document.querySelector('#upload-progress .upload-item.uploading')) {
              document.getElementById('upload-indicator')?.classList.add('hidden');
              document.getElementById('upload-panel')?.classList.add('hidden');
            }
          }, 5000);
        }
      };
      xhr.onerror = () => {
        active--;
        item.classList.remove('uploading');
        item.classList.add('upload-fail');
        pct.textContent = 'Error ✗';
        _uploadQueue.done++;
        if (_uploadQueue.done >= _uploadQueue.total) { _uploadQueue.total = 0; _uploadQueue.done = 0; }
        _updateUploadIndicator();
        next();
      };
      xhr.open('POST', '/drive/upload');
      xhr.send(fd);
      _updateUploadIndicator();
    }

    next();
  }

  // --- Drop zone ---
  function initDropZone() {
    const zone = document.getElementById('drop-zone');
    if (!zone) return;

    const isInternalDrag = (e) => Array.from(e.dataTransfer.types).includes('application/x-file-id');
    let dragCount = 0;
    zone.addEventListener('dragenter', (e) => { e.preventDefault(); if (isInternalDrag(e)) return; dragCount++; zone.classList.add('drag-over'); });
    zone.addEventListener('dragleave', () => { dragCount--; if (dragCount === 0) zone.classList.remove('drag-over'); });
    zone.addEventListener('dragover', (e) => e.preventDefault());
    zone.addEventListener('drop', (e) => {
      e.preventDefault();
      dragCount = 0;
      zone.classList.remove('drag-over');
      if (isInternalDrag(e)) return;  // handled by dir row drop handler
      const files = e.dataTransfer.files;
      if (files.length) uploadFiles(files);
    });
  }

  function openFilePicker() {
    document.getElementById('file-input')?.click();
  }

  function handleFileSelect(input) {
    if (input.files.length) {
      uploadFiles(input.files);
      input.value = '';
    }
  }

  // --- Modal ---
  function showModal(html) {
    const backdrop = document.getElementById('modal-backdrop');
    const modal    = document.getElementById('modal');
    modal.innerHTML = html;
    htmx.process(modal);   // register hx-* attrs on dynamically inserted content
    backdrop.classList.remove('hidden');
    modal.classList.remove('hidden');
    modal.querySelector('input')?.focus();
  }

  function closeModal() {
    document.getElementById('modal-backdrop')?.classList.add('hidden');
    document.getElementById('modal')?.classList.add('hidden');
  }

  document.getElementById('modal-backdrop')?.addEventListener('click', closeModal);

  function createFolder(e) {
    e.preventDefault();
    const name = e.target.querySelector('[name="name"]')?.value?.trim();
    if (!name) return;
    const dirId = _currentDir() ?? currentDirId;
    const body = new URLSearchParams({ name });
    if (dirId != null) body.set('parent_id', String(dirId));
    fetch('/drive/directories', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body.toString(),
    }).then(() => {
      closeModal();
      htmx.trigger(document.body, 'fileListChanged');
      htmx.trigger(document.body, 'treeChanged');
    });
  }

  function showNewFolderModal() {
    const tpl = document.getElementById('new-folder-modal');
    if (!tpl) return;
    const html = tpl.innerHTML;
    showModal(html);
    document.querySelector('#modal input[name="name"]')?.focus();
  }

  // --- Action menus ---
  let openMenu = null;

  function closeMenus() {
    if (openMenu) { openMenu.remove(); openMenu = null; }
  }

  document.addEventListener('click', closeMenus);

  function showActions(evt, btn) {
    evt.stopPropagation();
    closeMenus();
    const id   = btn.dataset.id;
    const name = btn.dataset.name;
    const type = btn.dataset.type;
    const menu = document.createElement('div');
    menu.className = 'action-dropdown';
    if (type === 'dir') {
      menu.innerHTML = `
        <button onclick="DriveUI.navigate(${id})">Open</button>
        <button onclick="DriveUI.renameDir(${id})">Rename</button>
        <button class="danger" onclick="DriveUI.deleteDir(${id})">Delete</button>
      `;
    } else {
      menu.innerHTML = `
        <button onclick="DriveUI.renameFile(${id})">Rename</button>
        <button onclick="DriveUI.copyFile(${id})">Copy here</button>
        <button onclick="DriveUI.moveFile(${id})">Move</button>
        <a href="/drive/download/${id}" download="${escHtml(name)}">Download</a>
        <button class="danger" onclick="DriveUI.deleteFile(${id})">Trash it</button>
      `;
    }
    btn.closest('.action-menu').appendChild(menu);
    openMenu = menu;
    menu._name = name;
    menu._id   = id;
  }

  // --- File operations ---
  function deleteFile(fileId) {
    const name = openMenu?._name ?? 'this file';
    closeMenus();
    if (!confirm(`Move "${name}" to Trash?`)) return;
    htmx.ajax('DELETE', `/drive/files/${fileId}`, {
      target: `#file-${fileId}`,
      swap: 'outerHTML',
    });
  }

  function renameFile(fileId) {
    const current = openMenu?._name ?? '';
    closeMenus();
    const name = prompt('New name:', current);
    if (!name || name === current) return;
    htmx.ajax('PATCH', `/drive/files/${fileId}`, {
      target: `#file-${fileId}`,
      swap: 'outerHTML',
      values: { name },
    });
  }

  function copyFile(fileId) {
    closeMenus();
    const values = {};
    const curDir = _currentDir();
    if (curDir != null) values.dir_id = curDir;
    htmx.ajax('POST', `/drive/files/${fileId}/copy`, {
      target: 'body', swap: 'none', values,
    });
  }

  function moveFile(fileId) {
    closeMenus();
    const dest = prompt('Move to path (e.g. Photos/2026):');
    if (!dest) return;
    htmx.ajax('PATCH', `/drive/files/${fileId}`, {
      target: `#file-${fileId}`,
      swap: 'outerHTML',
      values: { to_path: dest },
    });
  }

  function deleteDir(dirId) {
    const name = openMenu?._name ?? 'this folder';
    closeMenus();
    if (!confirm(`Delete "${name}" and all its contents?`)) return;
    htmx.ajax('DELETE', `/drive/directories/${dirId}`, {
      target: 'body', swap: 'none',
    });
  }

  // Used by both the file-list action menu and jsTree context menu
  function renameDirById(dirId, current) {
    const name = prompt('New name:', current ?? '');
    if (!name || name === current) return;
    htmx.ajax('PATCH', `/drive/directories/${dirId}`, {
      target: 'body', swap: 'none',
      values: { name },
    });
  }

  function deleteDirById(dirId, name) {
    if (!confirm(`Delete "${name ?? 'this folder'}" and all its contents?`)) return;
    htmx.ajax('DELETE', `/drive/directories/${dirId}`, {
      target: 'body', swap: 'none',
    });
  }

  function renameDir(dirId) {
    const current = openMenu?._name ?? '';
    closeMenus();
    renameDirById(dirId, current);
  }

  // --- Column sorting ---
  let _sortCol = null, _sortDir = 1;

  function sortTable(th) {
    const col = th.dataset.sort;
    _sortDir = (col === _sortCol) ? -_sortDir : 1;
    _sortCol = col;
    const colIdx = th.cellIndex;

    document.querySelectorAll('th[data-sort] .sort-icon').forEach(s => s.textContent = '');
    const icon = th.querySelector('.sort-icon');
    if (icon) icon.textContent = _sortDir === 1 ? ' ▲' : ' ▼';

    const tbody = document.getElementById('file-tbody');
    if (!tbody) return;

    const cmp = (a, b) => {
      const av = a.cells[colIdx]?.dataset.val ?? '';
      const bv = b.cells[colIdx]?.dataset.val ?? '';
      if (col === 'size') return (parseFloat(av) - parseFloat(bv)) * _sortDir;
      return av.localeCompare(bv, undefined, { numeric: true, sensitivity: 'base' }) * _sortDir;
    };

    const dirs   = [...tbody.querySelectorAll('tr.dir-row')].sort(cmp);
    const files  = [...tbody.querySelectorAll('tr.file-row:not(.dir-row):not(.load-more-row):not(.empty-row)')].sort(cmp);
    const others = [...tbody.querySelectorAll('tr.load-more-row, tr.empty-row')];

    [...dirs, ...files, ...others].forEach(r => tbody.appendChild(r));
  }

  document.addEventListener('click', (e) => {
    const th = e.target.closest('th[data-sort]');
    if (th) sortTable(th);
  });

  // --- Right-click context menu ---

  function showContextMenu(e, row) {
    e.preventDefault();
    e.stopPropagation();
    closeMenus();
    const id   = row.dataset.id;
    const name = row.querySelector('.file-name')?.textContent.trim() ?? '';
    const type = row.dataset.type;
    const menu = document.createElement('div');
    menu.className = 'action-dropdown context-menu';

    if (type === 'dir') {
      menu.innerHTML = `
        <button onclick="DriveUI.navigate(${id})">Open</button>
        <button onclick="DriveUI.renameDirById(${id}, '${escAttr(name)}')">Rename</button>
        <button onclick="DriveUI.zipItem('dir', ${id})">Zip</button>
        <button onclick="DriveUI.showShareModal('dir', ${id}, '${escAttr(name)}')">Share</button>
        <button class="danger" onclick="DriveUI.deleteDirById(${id}, '${escAttr(name)}')">Delete</button>
      `;
    } else {
      menu.innerHTML = `
        <a href="/drive/download/${id}" download="${escAttr(name)}">Download</a>
        <button onclick="DriveUI.renameFile(${id})">Rename</button>
        <button onclick="DriveUI.zipItem('file', ${id})">Zip</button>
        <button onclick="DriveUI.showShareModal('file', ${id}, '${escAttr(name)}')">Share</button>
        <button class="danger" onclick="DriveUI.deleteFile(${id})">Trash it</button>
      `;
    }

    const x = Math.min(e.clientX, window.innerWidth  - 160);
    const y = Math.min(e.clientY, window.innerHeight - 160);
    menu.style.left = x + 'px';
    menu.style.top  = y + 'px';
    document.body.appendChild(menu);
    openMenu = menu;
    menu._name = name;
    menu._id   = id;
  }

  document.addEventListener('contextmenu', (e) => {
    const row = e.target.closest('#file-tbody .file-row');
    if (row) showContextMenu(e, row);
  });

  // --- Sharing ---
  let _shareCtx = null;  // { type: 'file'|'dir', id, publicShareId: null }

  // Query inside the live #modal to avoid ID conflicts with the hidden template copy
  function _sm(id) {
    return document.getElementById('modal')?.querySelector('#' + id);
  }

  function showShareModal(type, id, name) {
    closeMenus();
    _shareCtx = { type, id, name, publicShareId: null };
    const tpl = document.getElementById('share-modal');
    if (!tpl) return;
    showModal(tpl.innerHTML);
    // Now work against the live #modal copy
    _sm('share-modal-name').textContent = name;
    _sm('share-tab-user').classList.remove('hidden');
    _sm('share-tab-public').classList.add('hidden');
    _sm('share-public-off').classList.remove('hidden');
    _sm('share-public-on').classList.add('hidden');
    _sm('share-existing-list').classList.add('hidden');
    // Activate first tab
    document.getElementById('modal').querySelectorAll('.share-tab')
      .forEach((t, i) => t.classList.toggle('active', i === 0));
    // Load existing shares
    _loadExistingShares(type, id);
  }

  function switchShareTab(btn, tab) {
    const m = document.getElementById('modal');
    m?.querySelectorAll('.share-tab').forEach(t => t.classList.remove('active'));
    btn.classList.add('active');
    _sm('share-tab-user')?.classList.toggle('hidden', tab !== 'user');
    _sm('share-tab-public')?.classList.toggle('hidden', tab !== 'public');
  }

  function _loadExistingShares(type, id) {
    fetch('/drive/shares')
      .then(r => r.json())
      .then(data => {
        if (!data.shares) return;
        const relevant = data.shares.filter(s =>
          (type === 'file' ? s.file_id == id : s.dir_id == id) && s.shared_with_email
        );
        const publicShare = data.shares.find(s =>
          (type === 'file' ? s.file_id == id : s.dir_id == id) && !s.shared_with_email
        );
        if (publicShare) {
          _shareCtx.publicShareId = publicShare.id;
          const url = `${window.location.origin}/s/${publicShare.share_token}`;
          _sm('share-public-off')?.classList.add('hidden');
          _sm('share-public-on')?.classList.remove('hidden');
          const inp = _sm('share-link-input');
          if (inp) inp.value = url;
        }
        if (relevant.length > 0) {
          const list  = _sm('share-existing-list');
          const items = _sm('share-existing-items');
          if (list)  list.classList.remove('hidden');
          if (items) items.innerHTML = relevant.map(s => `
            <div class="share-existing-item">
              <span>${escHtml(s.shared_with_email)}</span>
              <button class="btn btn-ghost btn-sm" onclick="DriveUI.revokeShare(${s.id})">Revoke</button>
            </div>`).join('');
        }
      });
  }

  function doShareWithUser() {
    const emailInp = _sm('share-email-input');
    const email = emailInp?.value?.trim();
    if (!email) return;
    const { type, id } = _shareCtx;
    const url = type === 'file' ? `/drive/files/${id}/share` : `/drive/directories/${id}/share`;
    fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ share_with: email }),
    }).then(r => r.json()).then(data => {
      const result = _sm('share-user-result');
      if (data.success) {
        if (result) result.textContent = `✓ Shared with ${email}`;
        if (emailInp) emailInp.value = '';
        _loadExistingShares(type, id);
      } else {
        if (result) result.textContent = `✗ ${data.error || 'Failed to share'}`;
      }
    });
  }

  function doSharePublic() {
    const { type, id } = _shareCtx;
    const url = type === 'file' ? `/drive/files/${id}/share` : `/drive/directories/${id}/share`;
    fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({}),  // no share_with = public
    }).then(r => r.json()).then(data => {
      if (data.success) {
        const shareUrl = `${window.location.origin}/s/${data.token}`;
        _shareCtx.publicShareId = data.share_id;
        _sm('share-public-off')?.classList.add('hidden');
        _sm('share-public-on')?.classList.remove('hidden');
        const inp = _sm('share-link-input');
        if (inp) inp.value = shareUrl;
      }
    });
  }

  function copyShareLink() {
    const inp = _sm('share-link-input');
    if (!inp) return;
    navigator.clipboard?.writeText(inp.value).catch(() => inp.select());
  }

  function revokePublicShare() {
    if (!_shareCtx?.publicShareId) return;
    revokeShare(_shareCtx.publicShareId, true);
  }

  function revokeShare(shareId, isPublic) {
    fetch(`/drive/shares/${shareId}`, { method: 'DELETE' })
      .then(r => r.json())
      .then(data => {
        if (data.success) {
          if (isPublic) {
            _shareCtx.publicShareId = null;
            document.getElementById('share-public-off')?.classList.remove('hidden');
            document.getElementById('share-public-on')?.classList.add('hidden');
          } else {
            _loadExistingShares(_shareCtx.type, _shareCtx.id);
          }
        }
      });
  }

  function zipItem(type, id) {
    closeMenus();
    const body = { dir_id: _currentDir(), file_ids: [], dir_ids: [] };
    if (type === 'file') body.file_ids = [parseInt(id, 10)];
    else                 body.dir_ids  = [parseInt(id, 10)];
    fetch('/drive/zip', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }).then(() => {
      htmx.trigger(document.body, 'fileListChanged');
      htmx.trigger(document.body, 'treeChanged');
    });
  }

  function bulkZip() {
    const { file_ids, dir_ids } = getSelectedIds();
    if (!file_ids.length && !dir_ids.length) return;
    fetch('/drive/zip', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ file_ids, dir_ids, dir_id: _currentDir() }),
    }).then(() => {
      clearSelection();
      htmx.trigger(document.body, 'fileListChanged');
      htmx.trigger(document.body, 'treeChanged');
    });
  }

  // --- Utilities ---
  function escHtml(str) {
    return str.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  function escAttr(str) {
    return String(str).replace(/\\/g, '\\\\').replace(/'/g, "\\'");
  }

  // --- Safe navigation (warns if uploads are in progress) ---
  function _uploadsActive() {
    return !!document.querySelector('#upload-progress .upload-item.uploading');
  }

  // Use for any full-page navigation (Trash, logout, etc.)
  // Returns false (cancels default link) if user declines; navigates and returns false otherwise.
  function safeNavigate(url) {
    if (_uploadsActive()) {
      if (!confirm('You have uploads in progress. Navigating away will cancel them.\n\nContinue?')) {
        return false;
      }
    }
    window.location.href = url;
    return false;
  }

  // Catch browser back/forward/close when uploads are in progress
  window.addEventListener('beforeunload', (e) => {
    if (_uploadsActive()) {
      e.preventDefault();
      e.returnValue = '';  // required for Chrome to show the dialog
    }
  });

  // --- Multi-select ---

  function _getSelectedRows() {
    return [...document.querySelectorAll('#file-tbody .file-row.selected')];
  }

  function getSelectedIds() {
    const rows = _getSelectedRows();
    return {
      file_ids: rows.filter(r => r.dataset.type === 'file').map(r => parseInt(r.dataset.id, 10)),
      dir_ids:  rows.filter(r => r.dataset.type === 'dir').map(r => parseInt(r.dataset.id, 10)),
    };
  }

  function onRowCheck() {
    // Sync row .selected class with checkbox state
    document.querySelectorAll('#file-tbody .row-check').forEach(cb => {
      cb.closest('.file-row')?.classList.toggle('selected', cb.checked);
    });
    _updateBulkToolbar();
  }

  function toggleSelect(row, e) {
    // Don't toggle if clicking a link, button, or checkbox directly
    if (e.target.closest('a, button, input')) return;
    const cb = row.querySelector('.row-check');
    if (cb) { cb.checked = !cb.checked; row.classList.toggle('selected', cb.checked); }
    _updateBulkToolbar();
  }

  function toggleSelectAll(masterCb) {
    document.querySelectorAll('#file-tbody .row-check').forEach(cb => {
      cb.checked = masterCb.checked;
      cb.closest('.file-row')?.classList.toggle('selected', cb.checked);
    });
    _updateBulkToolbar();
  }

  function clearSelection() {
    document.querySelectorAll('#file-tbody .row-check').forEach(cb => {
      cb.checked = false;
      cb.closest('.file-row')?.classList.remove('selected');
    });
    const masterCb = document.getElementById('select-all');
    if (masterCb) masterCb.checked = false;
    _updateBulkToolbar();
  }

  function _updateBulkToolbar() {
    const count   = _getSelectedRows().length;
    const toolbar = document.getElementById('bulk-toolbar');
    const label   = document.getElementById('bulk-count');
    if (toolbar) toolbar.classList.toggle('hidden', count === 0);
    if (label)   label.textContent = `${count} selected`;
    // Show Restore/Empty Trash buttons only when browsing the Trash directory
    const inTrash = document.body.dataset.trashDirId &&
                    String(_currentDir()) === String(document.body.dataset.trashDirId);
    const trashBtn      = document.getElementById('bulk-trash-btn');
    const restoreBtn    = document.getElementById('bulk-restore-btn');
    const emptyTrashBtn = document.getElementById('empty-trash-btn');
    if (trashBtn)      trashBtn.style.display   = inTrash ? 'none' : '';
    if (restoreBtn)    restoreBtn.style.display = inTrash ? '' : 'none';
    const zipBtn = document.getElementById('bulk-zip-btn');
    if (zipBtn)        zipBtn.style.display     = inTrash ? 'none' : '';
    _updateEmptyTrashBtn();
    // Clear select-all if not everything is checked
    const masterCb = document.getElementById('select-all');
    if (masterCb) {
      const total = document.querySelectorAll('#file-tbody .row-check').length;
      masterCb.checked = count > 0 && count === total;
      masterCb.indeterminate = count > 0 && count < total;
    }
  }

  function bulkTrash() {
    const { file_ids, dir_ids } = getSelectedIds();
    if (!file_ids.length && !dir_ids.length) return;

    let msg = `Move ${file_ids.length} file(s) to Trash?`;
    if (dir_ids.length > 0) {
      msg = `Move ${file_ids.length} file(s) to Trash?\n\n` +
            `⚠️  WARNING: You have also selected ${dir_ids.length} folder(s).\n` +
            `Trashing a folder will trash ALL files inside it recursively.\n\n` +
            `Are you absolutely sure you want to trash the folders too?`;
    }
    if (!confirm(msg)) return;

    const current_dir_id = _currentDir();
    fetch('/drive/bulk/trash', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ file_ids, dir_ids, current_dir_id }),
    }).then(r => r.json()).then(data => {
      clearSelection();
      htmx.trigger(document.body, 'fileListChanged');
      htmx.trigger(document.body, 'treeChanged');
    });
  }

  function _updateEmptyTrashBtn() {
    const inTrash = document.body.dataset.trashDirId &&
                    String(_currentDir()) === String(document.body.dataset.trashDirId);
    const btn = document.getElementById('empty-trash-btn');
    if (btn) btn.style.display = inTrash ? '' : 'none';
  }

  function emptyTrash() {
    if (!confirm('Permanently delete ALL files in Trash? This cannot be undone.')) return;
    fetch('/drive/trash', { method: 'DELETE' })
      .then(r => {
        if (r.ok || r.redirected) {
          htmx.trigger(document.body, 'fileListChanged');
          htmx.trigger(document.body, 'treeChanged');
        }
      });
  }

  function bulkRestore() {
    const { file_ids } = getSelectedIds();
    if (!file_ids.length) return;
    _movePendingIds = { file_ids, dir_ids: [], isRestore: true };
    const tpl = document.getElementById('move-picker-modal');
    if (!tpl) return;
    showModal(tpl.innerHTML.replace('<h3>Move to folder</h3>', '<h3>Restore to folder</h3>'));
    const modal    = document.getElementById('modal');
    const treeEl   = $(modal).find('.move-picker-tree').first();
    const lblEl    = modal.querySelector('.move-picker-label');
    const confirmBtn = modal.querySelector('.move-picker-confirm');

    let selectedDirId = null;
    const rootRadio = modal.querySelector('.move-root-radio');
    rootRadio?.addEventListener('change', () => {
      selectedDirId = null;
      treeEl.jstree(true)?.deselect_all(true);
      if (lblEl) lblEl.textContent = '🏠 My Drive (root)';
    });
    treeEl.jstree({
      core: { data: { url: '/drive/tree.json' }, themes: { dots: true, icons: true } },
      plugins: ['wholerow'],
    })
    .on('select_node.jstree', function(e, data) {
      selectedDirId = parseInt(data.node.id, 10);
      if (rootRadio) rootRadio.checked = false;
      if (lblEl) lblEl.textContent = data.node.text;
    });
    confirmBtn?.addEventListener('click', () => {
      if (selectedDirId === undefined) { alert('Please select a destination.'); return; }
      const ids = _movePendingIds;
      _movePendingIds = null;
      closeModal();
      fetch('/drive/bulk/restore', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ file_ids: ids.file_ids, dir_id: selectedDirId }),
      }).then(() => {
        clearSelection();
        htmx.trigger(document.body, 'fileListChanged');
        htmx.trigger(document.body, 'treeChanged');
      });
    });
  }

  let _movePendingIds = null;

  function showMovePicker() {
    const { file_ids, dir_ids } = getSelectedIds();
    if (!file_ids.length && !dir_ids.length) return;
    _movePendingIds = { file_ids, dir_ids };

    const tpl = document.getElementById('move-picker-modal');
    if (!tpl) return;
    showModal(tpl.innerHTML);

    // Use the modal element as context — avoids duplicate-id collisions with the hidden template
    const modal = document.getElementById('modal');
    const treeEl  = $(modal).find('.move-picker-tree').first();
    const lblEl   = modal.querySelector('.move-picker-label');
    const confirmBtn = modal.querySelector('.move-picker-confirm');

    let selectedDirId = undefined;  // undefined = nothing chosen yet
    const rootRadio = modal.querySelector('.move-root-radio');

    const updateLabel = (text) => { if (lblEl) lblEl.textContent = text; };

    // Root radio clears jsTree selection
    rootRadio?.addEventListener('change', () => {
      selectedDirId = null;
      treeEl.jstree(true)?.deselect_all(true);
      updateLabel('🏠 My Drive (root)');
    });

    treeEl.jstree({
      core: { data: { url: '/drive/tree.json' }, themes: { dots: true, icons: true } },
      plugins: ['wholerow'],
    })
    .on('select_node.jstree', function(e, data) {
      selectedDirId = parseInt(data.node.id, 10);
      if (rootRadio) rootRadio.checked = false;
      updateLabel(data.node.text);
    })
    .on('deselect_node.jstree', function() {
      if (selectedDirId !== null) { selectedDirId = undefined; updateLabel('—'); }
    });

    confirmBtn?.addEventListener('click', () => {
      if (selectedDirId === undefined) { alert('Please select a destination folder.'); return; }
      const ids = _movePendingIds;
      _movePendingIds = null;
      closeModal();
      _doBulkMove(ids.file_ids, ids.dir_ids, selectedDirId);
    });
  }

  function _doBulkMove(file_ids, dir_ids, dir_id) {
    fetch('/drive/bulk/move', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ file_ids, dir_ids, dir_id }),
    })
    .then(r => r.json())
    .then(data => {
      if (!data.success) {
        alert(`Move failed: ${data.error || 'Unknown error'}`);
        return;
      }
      clearSelection();
      htmx.trigger(document.body, 'fileListChanged');
      htmx.trigger(document.body, 'treeChanged');

      const moved   = data.moved   ?? [];
      const skipped = data.skipped ?? [];
      if (skipped.length > 0) {
        _showMoveResults(moved.length, skipped);
      }
    })
    .catch(e => alert(`Move error: ${e}`));
  }

  function _showMoveResults(movedCount, skipped) {
    const rows = skipped.map(f =>
      `<div class="move-result-row">
         <span class="move-result-icon">❌</span>
         <span class="move-result-name">${escHtml(f.name)}</span>
         <span class="move-result-reason">${escHtml(f.reason)}</span>
       </div>`
    ).join('');
    showModal(`
      <h3>Move Results</h3>
      <p class="move-results-summary">
        ✅ <strong>${movedCount}</strong> moved &nbsp;|&nbsp;
        ❌ <strong>${skipped.length}</strong> skipped
      </p>
      <div class="move-results-list">${rows}</div>
      <div class="form-actions">
        <button class="btn btn-primary" onclick="DriveUI.closeModal()">OK</button>
      </div>
    `);
  }

  // Clear selection when file list reloads
  document.body.addEventListener('fileListChanged', clearSelection);

  // --- Video player ---
  function playVideo(id, name, mime) {
    const modal  = document.getElementById('video-modal');
    const player = document.getElementById('video-player');
    const title  = document.getElementById('video-modal-title');
    if (!modal || !player) return;
    if (title) title.textContent = name;
    player.src  = `/drive/download/${id}`;
    player.type = mime || 'video/mp4';
    modal.classList.remove('hidden');
  }

  function closeVideo() {
    const player = document.getElementById('video-player');
    if (player) { player.pause(); player.src = ''; }
    document.getElementById('video-modal')?.classList.add('hidden');
  }

  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') closeVideo();
  });

  // --- Init ---
  document.addEventListener('DOMContentLoaded', () => {
    initDropZone();
    const params = new URLSearchParams(location.search);
    const d = params.get('dir_id');
    if (d) currentDirId = parseInt(d, 10);
    initTree(currentDirId);
    _updateEmptyTrashBtn();
  });

  return {
    navigate,
    toggleSidebar,
    closeSidebar,
    fileDragStart,
    fileDragEnd,
    dirDragOver,
    dirDragLeave,
    dirDrop,
    homeDragOver,
    homeDragLeave,
    homeDrop,
    toggleUploadPanel,
    safeNavigate,
    openFilePicker,
    handleFileSelect,
    showModal,
    closeModal,
    createFolder,
    showNewFolderModal,
    showActions,
    deleteFile,
    renameFile,
    copyFile,
    moveFile,
    deleteDir,
    renameDir,
    showContextMenu,
    zipItem,
    showShareModal,
    switchShareTab,
    doShareWithUser,
    doSharePublic,
    copyShareLink,
    revokePublicShare,
    revokeShare,
    playVideo,
    closeVideo,
    toggleSelect,
    toggleSelectAll,
    onRowCheck,
    clearSelection,
    bulkTrash,
    bulkRestore,
    bulkZip,
    emptyTrash,
    showMovePicker,
  };
})();
