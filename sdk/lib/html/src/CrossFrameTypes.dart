// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of html;

/**
 * An object representing the top-level context object for web scripting.
 *
 * In a web browser, a [Window] object represents the actual browser window.
 * In a multi-tabbed browser, each tab has its own [Window] object. A [Window]
 * is the container that displays a [Document]'s content. All web scripting
 * happens within the context of a [Window] object.
 *
 * **Note:** This class represents any window, whereas [LocalWindow] is
 * used to access the properties and content of the current window.
 *
 * See also:
 *
 * * [DOM Window](https://developer.mozilla.org/en-US/docs/DOM/window) from MDN.
 * * [Window](http://www.w3.org/TR/Window/) from the W3C.
 */
abstract class Window {
  // Fields.

  /**
   * The current location of this window.
   *
   *     Location currentLocation = window.location;
   *     print(currentLocation.href); // 'http://www.example.com:80/'
   */
  Location get location;
  History get history;

  /**
   * Indicates whether this window has been closed.
   *
   *     print(window.closed); // 'false'
   *     window.close();
   *     print(window.closed); // 'true'
   */
  bool get closed;

  /**
   * A reference to the window that opened this one.
   *
   *     Window thisWindow = window;
   *     Window otherWindow = thisWindow.open('http://www.example.com/', 'foo');
   *     print(otherWindow.opener == thisWindow); // 'true'
   */
  Window get opener;

  /**
   * A reference to the parent of this window.
   *
   * If this [Window] has no parent, [parent] will return a reference to
   * the [Window] itself.
   *
   *     IFrameElement myIFrame = new IFrameElement();
   *     window.document.body.elements.add(myIFrame);
   *     print(myIframe.contentWindow.parent == window) // 'true'
   *
   *     print(window.parent == window) // 'true'
   */
  Window get parent;

  /**
   * A reference to the topmost window in the window hierarchy.
   *
   * If this [Window] is the topmost [Window], [top] will return a reference to
   * the [Window] itself.
   *
   *     // Add an IFrame to the current window.
   *     IFrameElement myIFrame = new IFrameElement();
   *     window.document.body.elements.add(myIFrame);
   *
   *     // Add an IFrame inside of the other IFrame.
   *     IFrameElement innerIFrame = new IFrameElement();
   *     myIFrame.elements.add(innerIFrame);
   *
   *     print(myIframe.contentWindow.top == window) // 'true'
   *     print(innerIFrame.contentWindow.top == window) // 'true'
   *
   *     print(window.top == window) // 'true'
   */
  Window get top;

  // Methods.
  /**
   * Closes the window.
   *
   * This method should only succeed if the [Window] object is
   * **script-closeable** and the window calling [close] is allowed to navigate
   * the window.
   *
   * A window is script-closeable if it is either a window
   * that was opened by another window, or if it is a window with only one
   * document in its history.
   *
   * A window might not be allowed to navigate, and therefore close, another
   * window due to browser security features.
   *
   *     var other = window.open('http://www.example.com', 'foo');
   *     // Closes other window, as it is script-closeable.
   *     other.close();
   *     print(other.closed()); // 'true'
   *
   *     window.location('http://www.mysite.com', 'foo');
   *     // Does not close this window, as the history has changed.
   *     window.close();
   *     print(window.closed()); // 'false'
   *
   * See also:
   *
   * * [Window close discussion](http://www.w3.org/TR/html5/browsers.html#dom-window-close) from the W3C
   */
  void close();
  void postMessage(var message, String targetOrigin, [List messagePorts]);
}

abstract class Location {
  void set href(String val);
}

abstract class History {
  void back();
  void forward();
  void go(int distance);
}