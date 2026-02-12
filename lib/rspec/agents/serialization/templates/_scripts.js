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
