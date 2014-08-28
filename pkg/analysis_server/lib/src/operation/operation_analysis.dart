// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library operation.analysis;

import 'package:analysis_server/src/analysis_server.dart';
import 'package:analysis_server/src/computer/computer_highlights.dart';
import 'package:analysis_server/src/computer/computer_navigation.dart';
import 'package:analysis_server/src/computer/computer_occurrences.dart';
import 'package:analysis_server/src/computer/computer_outline.dart';
import 'package:analysis_server/src/computer/computer_overrides.dart';
import 'package:analysis_server/src/operation/operation.dart';
import 'package:analysis_server/src/protocol.dart' as protocol;
import 'package:analysis_server/src/services/index/index.dart';
import 'package:analyzer/src/generated/ast.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/generated/error.dart';
import 'package:analyzer/src/generated/html.dart';
import 'package:analyzer/src/generated/source.dart';


void sendAnalysisNotificationErrors(AnalysisServer server, String file,
    LineInfo lineInfo, List<AnalysisError> errors) {
  server.sendNotification(new protocol.AnalysisErrorsParams(file,
      protocol.AnalysisError.listFromEngine(lineInfo, errors)).toNotification());
}


void sendAnalysisNotificationHighlights(AnalysisServer server, String file,
    CompilationUnit dartUnit) {
  server.sendNotification(new protocol.AnalysisHighlightsParams(file,
      new DartUnitHighlightsComputer(dartUnit).compute()).toNotification());
}


void sendAnalysisNotificationNavigation(AnalysisServer server, String file,
    CompilationUnit dartUnit) {
  server.sendNotification(new protocol.AnalysisNavigationParams(file,
      new DartUnitNavigationComputer(dartUnit).compute()).toNotification());
}


void sendAnalysisNotificationOccurrences(AnalysisServer server, String file,
    CompilationUnit dartUnit) {
  server.sendNotification(new protocol.AnalysisOccurrencesParams(file,
      new DartUnitOccurrencesComputer(dartUnit).compute()).toNotification());
}


void sendAnalysisNotificationOutline(AnalysisServer server,
    AnalysisContext context, Source source, CompilationUnit dartUnit) {
  server.sendNotification(new protocol.AnalysisOutlineParams(source.fullName,
      new DartUnitOutlineComputer(context, source,
          dartUnit).compute()).toNotification());
}


void sendAnalysisNotificationOverrides(AnalysisServer server, String file,
    CompilationUnit dartUnit) {
  server.sendNotification(new protocol.AnalysisOverridesParams(file,
      new DartUnitOverridesComputer(dartUnit).compute()).toNotification());
}


/**
 * Instances of [PerformAnalysisOperation] perform a single analysis task.
 */
class PerformAnalysisOperation extends ServerOperation {
  final AnalysisContext context;
  final bool isContinue;

  PerformAnalysisOperation(this.context, this.isContinue);

  @override
  ServerOperationPriority get priority {
    if (isContinue) {
      return ServerOperationPriority.ANALYSIS_CONTINUE;
    } else {
      return ServerOperationPriority.ANALYSIS;
    }
  }

  @override
  void perform(AnalysisServer server) {
    //
    // TODO(brianwilkerson) Add an optional function-valued parameter to
    // performAnalysisTask that will be called when the task has been computed
    // but before it is performed and send notification in the function:
    //
    // AnalysisResult result = context.performAnalysisTask((taskDescription) {
    //   sendStatusNotification(context.toString(), taskDescription);
    // });
    // prepare results
    AnalysisResult result = context.performAnalysisTask();
    List<ChangeNotice> notices = result.changeNotices;
    if (notices == null) {
      server.sendContextAnalysisDoneNotifications(context);
      return;
    }
    // process results
    sendNotices(server, notices);
    updateIndex(server.index, notices);
    // continue analysis
    server.addOperation(new PerformAnalysisOperation(context, true));
  }

  /**
   * Send the information in the given list of notices back to the client.
   */
  void sendNotices(AnalysisServer server, List<ChangeNotice> notices) {
    for (int i = 0; i < notices.length; i++) {
      ChangeNotice notice = notices[i];
      Source source = notice.source;
      String file = source.fullName;
      // Dart
      CompilationUnit dartUnit = notice.compilationUnit;
      if (dartUnit != null) {
        if (server.hasAnalysisSubscription(protocol.AnalysisService.HIGHLIGHTS, file)) {
          sendAnalysisNotificationHighlights(server, file, dartUnit);
        }
        if (server.hasAnalysisSubscription(protocol.AnalysisService.NAVIGATION, file)) {
          sendAnalysisNotificationNavigation(server, file, dartUnit);
        }
        if (server.hasAnalysisSubscription(protocol.AnalysisService.OCCURRENCES, file)) {
          sendAnalysisNotificationOccurrences(server, file, dartUnit);
        }
        if (server.hasAnalysisSubscription(protocol.AnalysisService.OUTLINE, file)) {
          sendAnalysisNotificationOutline(server, context, source, dartUnit);
        }
        if (server.hasAnalysisSubscription(protocol.AnalysisService.OVERRIDES, file)) {
          sendAnalysisNotificationOverrides(server, file, dartUnit);
        }
      }
      if (server.shouldSendErrorsNotificationFor(file)) {
        sendAnalysisNotificationErrors(
            server,
            file,
            notice.lineInfo,
            notice.errors);
      }
    }
  }

  void updateIndex(Index index, List<ChangeNotice> notices) {
    if (index == null) {
      return;
    }
    for (ChangeNotice notice in notices) {
      // Dart
      {
        CompilationUnit dartUnit = notice.compilationUnit;
        if (dartUnit != null) {
          index.indexUnit(context, dartUnit);
        }
      }
      // HTML
      {
        HtmlUnit htmlUnit = notice.htmlUnit;
        if (htmlUnit != null) {
          index.indexHtmlUnit(context, htmlUnit);
        }
      }
    }
  }
}