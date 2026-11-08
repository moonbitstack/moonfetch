// The theme is decided before the sheet is painted, so that a page opened in the dark does not
// flash white. With no stored choice the system decides, through the stylesheet's
// `prefers-color-scheme` block; a choice made on one page is the one every other page opens with.

(() => {
  const KEY = "moonfetch-theme";
  let saved = null;
  try {
    saved = localStorage.getItem(KEY);
  } catch {
    // A browser that refuses storage still has its system theme.
  }
  if (saved === "light" || saved === "dark") {
    const root = document.documentElement;
    root.dataset.theme = saved;
    // The canvas before the stylesheet arrives is the theme's too, so a light sheet on a dark
    // system does not begin with a dark band.
    root.style.colorScheme = saved;
  }
})();
