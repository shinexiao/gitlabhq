(function() {
  (function(w) {
    var base;
    w.gl || (w.gl = {});
    (base = w.gl).utils || (base.utils = {});
    w.gl.utils.isInGroupsPage = function() {
      return gl.utils.getPagePath() === 'groups';
    };
    w.gl.utils.isInProjectPage = function() {
      return gl.utils.getPagePath() === 'projects';
    };
    w.gl.utils.getProjectSlug = function() {
      if (this.isInProjectPage()) {
        return $('body').data('project');
      } else {
        return null;
      }
    };
    w.gl.utils.getGroupSlug = function() {
      if (this.isInGroupsPage()) {
        return $('body').data('group');
      } else {
        return null;
      }
    };
    gl.utils.updateTooltipTitle = function($tooltipEl, newTitle) {
      return $tooltipEl.tooltip('destroy').attr('title', newTitle).tooltip('fixTitle');
    };
    gl.utils.preventDisabledButtons = function() {
      return $('.btn').click(function(e) {
        if ($(this).hasClass('disabled')) {
          e.preventDefault();
          e.stopImmediatePropagation();
          return false;
        }
      });
    };
    gl.utils.getPagePath = function() {
      return $('body').data('page').split(':')[0];
    };
    gl.utils.parseUrl = function (url) {
      var parser = document.createElement('a');
      parser.href = url;
      return parser;
    };
    return jQuery.timefor = function(time, suffix, expiredLabel) {
      var suffixFromNow, timefor;
      if (!time) {
        return '';
      }
      suffix || (suffix = 'remaining');
      expiredLabel || (expiredLabel = 'Past due');
      jQuery.timeago.settings.allowFuture = true;
      suffixFromNow = jQuery.timeago.settings.strings.suffixFromNow;
      jQuery.timeago.settings.strings.suffixFromNow = suffix;
      timefor = $.timeago(time);
      if (timefor.indexOf('ago') > -1) {
        timefor = expiredLabel;
      }
      jQuery.timeago.settings.strings.suffixFromNow = suffixFromNow;
      return timefor;
    };
  })(window);

}).call(this);
