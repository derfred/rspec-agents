// Base reusable components for RSpec Agents templates (Alpine.js)
document.addEventListener('alpine:init', function() {
  // ========================================
  // Modal Store
  // ========================================
  Alpine.store('modal', {
    visible: false,
    title: '',
    content: '',
    isHtml: false,

    show: function(title, content, options) {
      options = options || {};
      this.title = title;
      this.content = content;
      this.isHtml = options.isHtml || false;
      this.visible = true;
    },

    close: function() {
      this.visible = false;
    }
  });
});

// Global helpers for onclick attributes in extension-generated HTML
window.showModal = function(title, content, options) {
  Alpine.store('modal').show(title, content, options);
};
window.closeModal = function() {
  Alpine.store('modal').close();
};

window.copyToClipboard = function(text, button) {
  navigator.clipboard.writeText(text).then(function() {
    if (button) {
      var originalText = button.textContent;
      button.textContent = '\u2713 Copied!';
      setTimeout(function() {
        button.textContent = originalText;
      }, 2000);
    }
  }).catch(function(err) {
    console.error('Failed to copy:', err);
  });
};
