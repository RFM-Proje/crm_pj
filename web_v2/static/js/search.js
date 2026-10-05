// 고객 검색 자동완성 - data-ac 가 붙은 모든 입력창에 같은 흰색 목록을 붙인다 (상단 검색 · Customer 360)
(function () {
  const inputs = document.querySelectorAll("input[data-ac]");
  if (!inputs.length) return;
  let list = null;
  const load = () => list ? Promise.resolve(list)
    : fetch("/api/names").then(r => r.json()).then(d => (list = d));
  const esc = s => s.replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const icon = '<span class="ac-ico"><svg width="14" height="14" viewBox="0 0 24 24" fill="none"><circle cx="11" cy="11" r="7" stroke="currentColor" stroke-width="2"/><path d="M20 20l-3.5-3.5" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg></span>';
  // 입력한 부분은 보통 굵기, 나머지를 굵게 (네이버 검색어 추천 방식)
  const mark = (text, q) => {
    const i = text.toLowerCase().indexOf(q.toLowerCase());
    if (!q || i < 0) return `<b>${esc(text)}</b>`;
    return `<b>${esc(text.slice(0, i))}</b>${esc(text.slice(i, i + q.length))}<b>${esc(text.slice(i + q.length))}</b>`;
  };

  inputs.forEach(input => {
    const form = input.form;
    let wrap = input.closest(".ac-wrap");
    if (!wrap) { wrap = document.createElement("div"); wrap.className = "ac-wrap"; input.parentNode.insertBefore(wrap, input); wrap.appendChild(input); }
    const box = document.createElement("div");
    box.className = "ac-box"; box.setAttribute("role", "listbox");
    wrap.appendChild(box);
    let items = [], active = -1;

    const close = () => { box.classList.remove("on"); active = -1; };
    const go = it => { location.href = "/customer?q=" + encodeURIComponent(it.id); };
    const paint = () => box.querySelectorAll(".ac-item").forEach((el, i) => el.classList.toggle("on", i === active));
    const render = () => {
      const q = input.value.trim();
      load().then(all => {
        items = (q ? all.filter(d => d.n.toLowerCase().includes(q.toLowerCase()) || d.id.toLowerCase().includes(q.toLowerCase())) : all).slice(0, 8);
        if (!items.length) {
          box.innerHTML = q ? `<div class="ac-empty">'${esc(q)}'와 일치하는 고객이 없습니다</div>` : "";
        } else {
          box.innerHTML = (q ? "" : '<div class="ac-cap">가치위험 우선순위 상위 고객</div>') + items.map((d, i) =>
            `<div class="ac-item" data-i="${i}" role="option">${icon}<span class="ac-name">${mark(d.n, q)}</span>` +
            `<span class="ac-id">${mark(d.id, q)}</span><span class="tier ${d.t}">${d.t}</span>` +
            `<span class="ac-go"><svg width="14" height="14" viewBox="0 0 24 24" fill="none"><path d="M7 17L17 7M17 7H9M17 7v8" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg></span></div>`).join("");
        }
        active = -1;
        box.classList.toggle("on", !!box.innerHTML);
      });
    };
    input.addEventListener("focus", render);
    input.addEventListener("input", render);
    input.addEventListener("keydown", e => {
      if (!box.classList.contains("on")) return;
      if (e.key === "ArrowDown") { active = Math.min(active + 1, items.length - 1); paint(); e.preventDefault(); }
      else if (e.key === "ArrowUp") { active = Math.max(active - 1, 0); paint(); e.preventDefault(); }
      else if (e.key === "Enter" && active >= 0) { go(items[active]); e.preventDefault(); }
      else if (e.key === "Escape") close();
    });
    box.addEventListener("mousedown", e => {      // blur 보다 먼저 처리
      const el = e.target.closest(".ac-item");
      if (el) { e.preventDefault(); go(items[+el.dataset.i]); }
    });
    box.addEventListener("mousemove", e => { const el = e.target.closest(".ac-item"); if (el) { active = +el.dataset.i; paint(); } });
    input.addEventListener("blur", () => setTimeout(close, 120));
    if (form) form.addEventListener("submit", e => { if (!input.value.trim()) e.preventDefault(); });
  });
})();
