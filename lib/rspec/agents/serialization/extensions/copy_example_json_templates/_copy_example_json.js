// ========================================
// Copy Example JSON System
// ========================================

document.addEventListener('alpine:init', function() {
  // Add copyExampleJson to the suite store
  Alpine.store('suite').copyExampleJson = function(buttonElement) {
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
  };
});
