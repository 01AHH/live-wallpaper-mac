// Cosmetic lock screen shared by every page: any non-empty password unlocks,
// remembered per browser. Not a security boundary.
const gate = document.getElementById('gate');
let unlocked = false;
try { unlocked = localStorage.getItem('livewall-unlocked') === '1'; } catch {}
if (!unlocked && gate) {
  gate.hidden = false;
  const input = document.getElementById('gate-input');
  input.focus();
  document.getElementById('gate-form').addEventListener('submit', (e) => {
    e.preventDefault();
    if (!input.value.trim()) {
      gate.classList.remove('shake'); void gate.offsetWidth; gate.classList.add('shake');
      return;
    }
    try { localStorage.setItem('livewall-unlocked', '1'); } catch {}
    gate.hidden = true;
  });
}
