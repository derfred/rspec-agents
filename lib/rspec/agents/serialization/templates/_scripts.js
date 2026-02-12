// RSpec Agents - Core UI (Alpine.js)
document.addEventListener('alpine:init', function() {

  // ========================================
  // Suite Navigation Store
  // ========================================
  Alpine.store('suite', {
    view: 'summary', // 'summary' or 'details'
    activeExampleId: null,
    metadataVisible: false,
    metadataMessageId: null,
    metadataRole: '',

    showSummary: function() {
      this.view = 'summary';
      this.metadataVisible = false;
    },

    showDetails: function() {
      this.view = 'details';
      if (!this.activeExampleId) {
        var first = document.querySelector('.example-item');
        if (first) {
          this.activeExampleId = first.getAttribute('data-example');
        }
      }
    },

    showExample: function(exampleId) {
      this.activeExampleId = exampleId;
    },

    navigateToExample: function(exampleId) {
      this.view = 'details';
      this.activeExampleId = exampleId;
    },

    showMetadata: function(messageId, messageRole) {
      this.metadataMessageId = messageId;
      this.metadataRole = messageRole.charAt(0).toUpperCase() + messageRole.slice(1) + ' Message Metadata';
      this.metadataVisible = true;
    },

    closeMetadata: function() {
      this.metadataVisible = false;
      this.metadataMessageId = null;
    },

    copyExampleJson: function(buttonElement) {
      var exampleContent = buttonElement.closest('.example-content');
      if (!exampleContent) return;
      var jsonData = exampleContent.getAttribute('data-example');
      if (!jsonData) return;
      var formattedJson = JSON.stringify(JSON.parse(jsonData), null, 2);
      navigator.clipboard.writeText(formattedJson).then(function() {
        var originalText = buttonElement.innerHTML;
        buttonElement.innerHTML = '\u2713 Copied!';
        buttonElement.style.backgroundColor = '#22c55e';
        setTimeout(function() {
          buttonElement.innerHTML = originalText;
          buttonElement.style.backgroundColor = '';
        }, 2000);
      }).catch(function() {
        var originalText = buttonElement.innerHTML;
        buttonElement.innerHTML = '\u2717 Failed';
        buttonElement.style.backgroundColor = '#ef4444';
        setTimeout(function() {
          buttonElement.innerHTML = originalText;
          buttonElement.style.backgroundColor = '';
        }, 2000);
      });
    }
  });

  // ========================================
  // Expandable Store
  // ========================================
  Alpine.store('expandable', {
    expanded: {},

    toggle: function(id) {
      this.expanded[id] = !this.expanded[id];
    },

    isExpanded: function(id) {
      return !!this.expanded[id];
    }
  });
});
