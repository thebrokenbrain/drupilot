/**
 * @file
 * Counts the characters of a node title with a Backbone view.
 */
((Drupal, once, Backbone) => {
  const CounterView = Backbone.View.extend({
    events: { input: 'render' },
    render() {
      this.el.setAttribute('data-length', String(this.el.value.length));
      return this;
    },
  });

  Drupal.behaviors.d11ForD12TitleCounter = {
    attach(context) {
      once('d11-for-d12-title-counter', 'input[name="title[0][value]"]', context).forEach((el) => {
        new CounterView({ el }).render();
      });
    },
  };
})(Drupal, once, Backbone);
