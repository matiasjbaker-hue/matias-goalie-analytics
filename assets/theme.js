// Light / dark theme. Follows the device setting until the visitor
// picks one with the switch in the top bar; the choice is remembered
// in this browser. The page <head> applies a saved choice before
// first paint (see the inline snippet there) so there's no flash.

(function(){

  var KEY = "giq-theme";
  var media = window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;

  var MOON = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg>';
  var SUN = '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4.5"/><path d="M12 2v2.5M12 19.5V22M4.2 4.2l1.8 1.8M18 18l1.8 1.8M2 12h2.5M19.5 12H22M4.2 19.8 6 18M18 6l1.8-1.8"/></svg>';

  function current(){
    var set = document.documentElement.getAttribute("data-theme");
    if(set === "dark" || set === "light"){ return set; }
    return media && media.matches ? "dark" : "light";
  }

  function paint(){
    var theme = current();
    var buttons = document.querySelectorAll("[data-theme-toggle]");
    for(var i = 0; i < buttons.length; i++){
      var b = buttons[i];
      b.innerHTML = theme === "dark" ? SUN : MOON;
      b.setAttribute("aria-label", theme === "dark" ? "Switch to light mode" : "Switch to dark mode");
      b.setAttribute("title", theme === "dark" ? "Light mode" : "Dark mode");
      b.setAttribute("aria-pressed", theme === "dark" ? "true" : "false");
    }
    var meta = document.querySelector('meta[name="theme-color"]');
    if(meta){ meta.setAttribute("content", theme === "dark" ? "#070908" : "#0F4A35"); }
  }

  function announce(){
    paint();
    try{ window.dispatchEvent(new CustomEvent("giq-themechange", { detail: { theme: current() } })); }catch(e){}
  }

  window.toggleTheme = function(){
    var next = current() === "dark" ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", next);
    try{ localStorage.setItem(KEY, next); }catch(e){}
    announce();
  };

  window.currentTheme = current;

  if(media){
    var onChange = function(){
      if(!document.documentElement.getAttribute("data-theme")){ announce(); }
    };
    if(media.addEventListener){ media.addEventListener("change", onChange); }
    else if(media.addListener){ media.addListener(onChange); }
  }

  if(document.readyState === "loading"){ document.addEventListener("DOMContentLoaded", paint); }
  else{ paint(); }

})();
