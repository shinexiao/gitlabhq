(function() {
  this.ProjectFork = (function() {
    function ProjectFork() {
      $('.fork-thumbnail a').on('click', function() {
        $('.fork-namespaces').hide();
        return $('.save-project-loader').show();
      });
    }

    return ProjectFork;

  })();

}).call(this);
