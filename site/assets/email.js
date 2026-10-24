// Contact address, kept out of the HTML source so scrapers do not harvest it. The page shows a
// human-readable form; this script assembles the real address only when a visitor clicks.
(function () {
  document.querySelectorAll("[data-email]").forEach(function (box) {
    function address() {
      return box.getAttribute("data-user") + String.fromCharCode(64) +
        box.getAttribute("data-domain") + "." + box.getAttribute("data-tld");
    }
    var row = document.createElement("span");
    row.className = "email-actions";
    var copy = document.createElement("button");
    copy.type = "button";
    copy.className = "email-btn";
    copy.textContent = "Copy email";
    var write = document.createElement("button");
    write.type = "button";
    write.className = "email-btn";
    write.textContent = "Write email";
    var status = document.createElement("span");
    status.className = "email-status";
    status.setAttribute("aria-live", "polite");
    row.appendChild(copy);
    row.appendChild(write);
    row.appendChild(status);
    box.appendChild(row);

    var reset;
    function done(text) {
      status.textContent = text;
      copy.setAttribute("data-done", "");
      clearTimeout(reset);
      reset = setTimeout(function () { status.textContent = ""; copy.removeAttribute("data-done"); }, 2400);
    }
    copy.addEventListener("click", function () {
      var a = address();
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(a).then(function () { done("Copied"); }, function () { done(a); });
      } else {
        done(a);
      }
    });
    write.addEventListener("click", function () {
      window.location.href = "mail" + "to:" + address();
    });
  });
})();
