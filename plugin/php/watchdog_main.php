<?php
/*
 * Container Watchdog — Unraid web interface.
 *
 * Rendered inside the existing authenticated emhttp web server. The plugin still
 * opens no listener of its own. Every mutation goes through watchdog_action.php,
 * which delegates to the command line tool.
 */

$statusFile = '/run/container-watchdog/public/status.json';
$summary = [];
if (is_readable($statusFile)) {
    $decoded = json_decode((string) file_get_contents($statusFile), true);
    if (is_array($decoded)) {
        $summary = $decoded;
    }
}

function field(array $source, string $key, $fallback = '—')
{
    $value = $source[$key] ?? '';
    return ($value === '' || $value === null) ? $fallback : $value;
}

$breakglassPresent = is_executable('/usr/local/sbin/container-breakglass');
?>
<link rel="stylesheet" href="/plugins/container-watchdog/css/watchdog.css">

<div class="watchdog-summary">
  <div class="watchdog-tile watchdog-state-<?= htmlspecialchars(strtolower((string) field($summary, 'status', 'unknown')), ENT_QUOTES) ?>">
    <span class="watchdog-tile-label">Status</span>
    <span class="watchdog-tile-value"><?= htmlspecialchars((string) field($summary, 'status'), ENT_QUOTES) ?></span>
  </div>
  <div class="watchdog-tile">
    <span class="watchdog-tile-label">Watched</span>
    <span class="watchdog-tile-value"><?= htmlspecialchars((string) field($summary, 'watched', '0'), ENT_QUOTES) ?></span>
  </div>
  <div class="watchdog-tile">
    <span class="watchdog-tile-label">Failing</span>
    <span class="watchdog-tile-value"><?= htmlspecialchars((string) field($summary, 'failing', '0'), ENT_QUOTES) ?></span>
  </div>
  <div class="watchdog-tile">
    <span class="watchdog-tile-label">Suspended</span>
    <span class="watchdog-tile-value"><?= htmlspecialchars((string) field($summary, 'suspended', '0'), ENT_QUOTES) ?></span>
  </div>
  <div class="watchdog-tile">
    <span class="watchdog-tile-label">Repairs</span>
    <span class="watchdog-tile-value"><?= htmlspecialchars((string) field($summary, 'repairs', '0'), ENT_QUOTES) ?></span>
  </div>
  <div class="watchdog-tile">
    <span class="watchdog-tile-label">Failed repairs</span>
    <span class="watchdog-tile-value"><?= htmlspecialchars((string) field($summary, 'repairs_failed', '0'), ENT_QUOTES) ?></span>
  </div>
</div>

<?php if (!$breakglassPresent): ?>
<div class="watchdog-warning">
  Container Breakglass is not installed. The watchdog cannot see stop latches or
  deployment guards, so it will act on every fault it is allowed to repair.
</div>
<?php endif; ?>

<table class="watchdog-table">
  <thead>
    <tr>
      <th>Container</th>
      <th>Verdict</th>
      <th>May do</th>
      <th>Checks</th>
      <th>Networks</th>
      <th>Fails</th>
      <th>Repairs<br><span class="watchdog-subtle">in window</span></th>
      <th>Actions</th>
    </tr>
  </thead>
  <tbody id="watchdog-rows">
    <tr><td colspan="8" class="watchdog-subtle">Loading…</td></tr>
  </tbody>
</table>

<div class="watchdog-toolbar">
  <button type="button" class="watchdog-button" id="watchdog-refresh">Refresh</button>
  <button type="button" class="watchdog-button" id="watchdog-check">Run checks now</button>
  <span class="watchdog-subtle">Running checks never repairs anything.</span>
</div>

<pre id="watchdog-output" class="watchdog-output" hidden></pre>

<hr>

<h3>Watch another container</h3>
<form id="watchdog-add" class="watchdog-form" autocomplete="off">
  <dl>
    <dt>Container</dt>
    <dd>
      <input type="text" name="container" list="watchdog-container-names" required
             pattern="[A-Za-z0-9][A-Za-z0-9_.\-]{0,127}" placeholder="exact container name">
      <datalist id="watchdog-container-names"></datalist>
    </dd>

    <dt>May do</dt>
    <dd>
      <select name="action_level" id="watchdog-action">
        <option value="notify">notify — report only, never touch it</option>
        <option value="restart">restart — start when stopped, restart when broken</option>
        <option value="reattach">reattach — also reconnect a lost network</option>
      </select>
    </dd>

    <dt>Checks</dt>
    <dd>
      <label><input type="checkbox" name="check[]" value="running" checked> running</label>
      <label><input type="checkbox" name="check[]" value="health" checked> health</label>
      <label><input type="checkbox" name="check[]" value="network" checked> network</label>
      <label><input type="checkbox" name="check[]" value="ports" checked> ports</label>
      <label><input type="checkbox" name="check[]" value="http"> http probe</label>
    </dd>

    <dt>Networks</dt>
    <dd>
      <input type="text" name="networks" placeholder="comma separated, required for reattach">
      <span class="watchdog-subtle">The networks that must stay attached.</span>
    </dd>

    <dt>Probe URL</dt>
    <dd>
      <input type="text" name="http" placeholder="http://127.0.0.1:3000/">
      <span class="watchdog-subtle">Only used when the http check is enabled.</span>
    </dd>

    <dt>Restraint</dt>
    <dd>
      <input type="number" name="threshold" min="1" max="100" placeholder="3" title="Consecutive failures before acting">
      <input type="number" name="cooldown" min="60" max="86400" placeholder="600" title="Seconds between repairs">
      <input type="number" name="max_actions" min="1" max="20" placeholder="3" title="Repairs per window">
      <input type="number" name="window" min="300" max="86400" placeholder="3600" title="Window length in seconds">
      <span class="watchdog-subtle">Threshold · cooldown · repairs per window · window. Leave empty for defaults.</span>
    </dd>
  </dl>
  <button type="submit" class="watchdog-button">Save container</button>
</form>

<script>
(function () {
  const endpoint = '/plugins/container-watchdog/php/watchdog_action.php';
  const token = <?= json_encode((string) ($var['csrf_token'] ?? '')) ?>;
  const rows = document.getElementById('watchdog-rows');
  const output = document.getElementById('watchdog-output');

  function post(payload) {
    const body = new URLSearchParams();
    body.set('csrf_token', token);
    Object.entries(payload).forEach(([key, value]) => body.set(key, value));
    return fetch(endpoint, { method: 'POST', body })
      .then(response => response.json().catch(() => ({ ok: false, error: 'Malformed response' })));
  }

  function show(text) {
    output.hidden = !text;
    output.textContent = text || '';
  }

  function parseRecords(text) {
    return text.split('\n').filter(Boolean).map(line => {
      const record = {};
      line.split(' ').forEach(token => {
        const index = token.indexOf('=');
        if (index > 0) record[token.slice(0, index)] = token.slice(index + 1);
      });
      return record;
    });
  }

  function verdictBadge(record) {
    if (record.latched === 'yes') return '<span class="watchdog-badge watchdog-badge-latched">latched</span>';
    if (record.suspended === 'yes') return '<span class="watchdog-badge watchdog-badge-suspended">suspended</span>';
    if (record.verdict === 'fail') return '<span class="watchdog-badge watchdog-badge-fail">failing</span>';
    if (record.verdict === 'ok') return '<span class="watchdog-badge watchdog-badge-ok">ok</span>';
    return '<span class="watchdog-badge">unknown</span>';
  }

  function escape(value) {
    return String(value === undefined ? '' : value).replace(/[&<>"']/g, character => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[character]));
  }

  function render(records) {
    if (!records.length) {
      rows.innerHTML = '<tr><td colspan="8" class="watchdog-subtle">Nothing is being watched yet.</td></tr>';
      return;
    }
    rows.innerHTML = records.map(record => {
      const name = escape(record.container);
      const suspended = record.suspended === 'yes';
      return `<tr>
        <td><strong>${name}</strong></td>
        <td>${verdictBadge(record)}</td>
        <td>${escape(record.action)}</td>
        <td class="watchdog-subtle">${escape(record.checks)}</td>
        <td class="watchdog-subtle">${escape(record.networks)}</td>
        <td>${escape(record.fails)}</td>
        <td>${escape(record.repairs)}</td>
        <td class="watchdog-row-actions">
          <button type="button" data-op="${suspended ? 'resume' : 'suspend'}" data-container="${name}">${suspended ? 'Resume' : 'Suspend'}</button>
          <button type="button" data-op="reset" data-container="${name}">Reset</button>
          <button type="button" data-op="status" data-container="${name}">Details</button>
          <button type="button" data-op="remove" data-container="${name}" class="watchdog-danger">Remove</button>
        </td>
      </tr>`;
    }).join('');
  }

  function refresh() {
    return post({ op: 'report' }).then(result => {
      if (!result.ok) { show(result.error || 'Could not read the watchdog state.'); return; }
      render(parseRecords(result.output || ''));
    });
  }

  rows.addEventListener('click', event => {
    const button = event.target.closest('button[data-op]');
    if (!button) return;
    const operation = button.dataset.op;
    const container = button.dataset.container;
    if (operation === 'remove' && !confirm('Stop watching ' + container + '?')) return;
    button.disabled = true;
    post({ op: operation, container }).then(result => {
      show(result.output || result.error || '');
      return refresh();
    }).finally(() => { button.disabled = false; });
  });

  document.getElementById('watchdog-refresh').addEventListener('click', () => {
    show('');
    refresh();
  });

  document.getElementById('watchdog-check').addEventListener('click', event => {
    event.target.disabled = true;
    show('Running checks…');
    post({ op: 'check' }).then(result => {
      show(result.output || result.error || 'No output.');
      return refresh();
    }).finally(() => { event.target.disabled = false; });
  });

  document.getElementById('watchdog-add').addEventListener('submit', event => {
    event.preventDefault();
    const form = event.target;
    const checks = Array.from(form.querySelectorAll('input[name="check[]"]:checked')).map(box => box.value);
    if (!checks.length) { show('Select at least one check.'); return; }
    const payload = {
      op: 'save',
      container: form.container.value.trim(),
      action: form.action_level.value,
      checks: checks.join(','),
      networks: form.networks.value.trim(),
      http: form.http.value.trim()
    };
    ['threshold', 'cooldown', 'max_actions', 'window'].forEach(name => {
      const value = form[name].value.trim();
      if (value) payload[name] = value;
    });
    post(payload).then(result => {
      show(result.ok ? 'Saved ' + payload.container + '.' : (result.error || result.output));
      if (result.ok) form.reset();
      return refresh();
    });
  });

  post({ op: 'containers' }).then(result => {
    if (!result.ok) return;
    document.getElementById('watchdog-container-names').innerHTML =
      result.containers.map(name => `<option value="${escape(name)}"></option>`).join('');
  });

  refresh();
})();
</script>
