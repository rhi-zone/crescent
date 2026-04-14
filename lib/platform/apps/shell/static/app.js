(function () {
  "use strict";

  var grid = document.getElementById("card-grid");
  var emptyState = document.getElementById("empty-state");
  var searchInput = document.getElementById("search");
  var allCards = [];

  function escapeHtml(s) {
    var div = document.createElement("div");
    div.appendChild(document.createTextNode(s));
    return div.innerHTML;
  }

  function renderCards(cards) {
    grid.innerHTML = "";
    if (cards.length === 0) {
      emptyState.hidden = false;
      return;
    }
    emptyState.hidden = true;

    for (var i = 0; i < cards.length; i++) {
      var card = cards[i];
      var el = document.createElement("div");
      el.className = "card-item";
      el.setAttribute("data-filename", card.filename);

      var tagsHtml = "";
      if (card.tags && card.tags.length > 0) {
        tagsHtml = '<div class="card-tags">';
        for (var t = 0; t < card.tags.length && t < 3; t++) {
          tagsHtml += '<span class="card-tag">' + escapeHtml(card.tags[t]) + "</span>";
        }
        tagsHtml += "</div>";
      }

      el.innerHTML =
        '<img class="card-thumb" src="/api/card/thumbnail?filename=' +
        encodeURIComponent(card.filename) +
        '" alt="' + escapeHtml(card.name) + '" loading="lazy">' +
        '<div class="card-overlay">' +
        '<div class="card-name">' + escapeHtml(card.name) + "</div>" +
        '<div class="card-desc">' + escapeHtml(card.description || "") + "</div>" +
        tagsHtml +
        "</div>";

      el.addEventListener("click", (function (c) {
        return function () { launchCard(c); };
      })(card));

      grid.appendChild(el);
    }
  }

  function filterCards(query) {
    if (!query) {
      renderCards(allCards);
      return;
    }
    var q = query.toLowerCase();
    var filtered = allCards.filter(function (card) {
      if (card.name.toLowerCase().indexOf(q) !== -1) return true;
      if (card.description && card.description.toLowerCase().indexOf(q) !== -1) return true;
      if (card.tags) {
        for (var i = 0; i < card.tags.length; i++) {
          if (card.tags[i].toLowerCase().indexOf(q) !== -1) return true;
        }
      }
      return false;
    });
    renderCards(filtered);
  }

  function launchCard(card) {
    fetch("/api/launch", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ filename: card.filename }),
    })
      .then(function (res) { return res.json(); })
      .then(function (data) {
        console.log("Launch:", data);
        // Future: open the card app at data.port or in an iframe
      })
      .catch(function (err) {
        console.error("Launch failed:", err);
      });
  }

  function loadCards() {
    fetch("/api/cards")
      .then(function (res) { return res.json(); })
      .then(function (data) {
        allCards = data.cards || [];
        renderCards(allCards);
      })
      .catch(function (err) {
        console.error("Failed to load cards:", err);
        emptyState.hidden = false;
      });
  }

  searchInput.addEventListener("input", function () {
    filterCards(searchInput.value.trim());
  });

  loadCards();
})();
