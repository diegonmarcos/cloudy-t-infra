// ╔══════════════════════════════════════════════════════════════════╗
// ║                                                                  ║
// ║   GENERATED FILE — DO NOT EDIT                                   ║
// ║                                                                  ║
// ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-apps/src/pilot/html/pilot.js
// ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
// ║   Rebuild: ./9_others/build.sh
// ║                                                                  ║
// ║   Manual edits will be overwritten on next build.                ║
// ║                                                                  ║
// ╚══════════════════════════════════════════════════════════════════╝

// vm-pilot dashboard — sidebar data from health + cloud-data JSONs
(function () {
  var hamburger = document.getElementById('hamburger');
  var sidebar = document.getElementById('sidebar');
  var closeBtn = document.getElementById('close-btn');

  hamburger.addEventListener('click', function () { sidebar.classList.add('open'); });
  closeBtn.addEventListener('click', function () { sidebar.classList.remove('open'); });

  // ttyd iframe — runs on port 7681 (separate websocket server)
  var terminal = document.getElementById('terminal');
  if (terminal) {
    terminal.src = location.protocol + '//' + location.hostname + ':7681/ttyd/';
  }

  // Load config from health agent JSON
  fetch('/health/latest.json')
    .then(function (r) { return r.json(); })
    .then(function (health) {
      document.getElementById('vm-name').textContent = health.vm || 'vm-pilot';
      document.title = (health.vm || 'vm-pilot') + ' — pilot';

      var info = document.getElementById('vm-info');
      info.innerHTML =
        '<li><span class="label">Host</span> ' + health.vm + '</li>' +
        '<li><span class="label">Uptime</span> ' + health.uptime + '</li>' +
        '<li><span class="label">Load</span> ' + health.load + '</li>' +
        '<li><span class="label">Mem</span> ' + health.mem.used + '/' + health.mem.total + ' MB (' + health.mem.pct + '%)</li>' +
        '<li><span class="label">Disk</span> ' + health.disk.used + '/' + health.disk.total + ' (' + health.disk.pct + ')</li>' +
        '<li><span class="label">WG</span> ' + (health.wg_up ? 'up' : 'down') + '</li>' +
        '<li><span class="label">Containers</span> ' + health.containers_running + '/' + health.containers_total + '</li>';
    })
    .catch(function () {
      document.getElementById('vm-info').innerHTML = '<li>Health data unavailable</li>';
    });

  // Load cloud-data for services + other VMs
  // 2026-04-27 migrated: cloud-data-home-manager.json → _cloud-data-consolidated.json[._home_manager.vms]
  fetch('/pilot/data/_cloud-data-consolidated.json')
    .then(function (r) { return r.json(); })
    .then(function (data) {
      var hostname = location.hostname.replace('.app', '');
      var vmAlias = hostname;

      // Find current VM in data
      var vms = (data._home_manager && data._home_manager.vms) || data.vms || {};
      var servicesList = document.getElementById('services-list');
      var otherVms = document.getElementById('other-vms');

      // Services for current VM from cloud-data
      var currentVm = vms[vmAlias];
      if (currentVm && currentVm.services) {
        servicesList.innerHTML = currentVm.services.map(function (s) {
          return '<li><a href="https://' + (s.domain || s.name + '.diegonmarcos.com') + '" target="_blank">' + s.name + '</a></li>';
        }).join('');
      }

      // Other VMs
      Object.keys(vms).forEach(function (alias) {
        if (alias === vmAlias || alias === 'vast-ollama') return;
        var vm = vms[alias];
        var li = document.createElement('li');
        li.innerHTML = '<a href="https://' + alias + '.app/" target="_blank">' + alias + '</a>';
        otherVms.appendChild(li);
      });
    })
    .catch(function () { /* cloud-data not available, sidebar stays minimal */ });
})();
