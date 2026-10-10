// Feature-page mocks are drawn at a fixed design width (data-w) and zoomed to
// fit their column, so they look the same on a phone as on a big screen.
function fitMocks() {
  for (const mock of document.querySelectorAll('.fit > [data-w]')) {
    const room = mock.parentElement.clientWidth;
    mock.style.setProperty('--z', Math.min(1, room / Number(mock.dataset.w)));
  }
}
fitMocks();
addEventListener('resize', fitMocks);

// Span Screens: one video across both displays, or the full video on each.
// Like the app, both displays play one clip in lockstep, so the morph
// between the two layouts never shows a seam.
const screens = [...document.querySelectorAll('#displays video')];
if (screens.length > 1) {
  const [lead, ...rest] = screens;
  const sync = () => rest.forEach((v) => {
    if (Math.abs(v.currentTime - lead.currentTime) > 0.05) v.currentTime = lead.currentTime;
  });
  lead.addEventListener('playing', sync);
  lead.addEventListener('seeked', sync);
  setInterval(sync, 2000);
}
const span = document.getElementById('span-toggle');
span?.addEventListener('click', () => {
  const on = span.getAttribute('aria-checked') !== 'true';
  span.setAttribute('aria-checked', String(on));
  document.querySelectorAll('#displays .display').forEach((d) => d.classList.toggle('own', !on));
});
