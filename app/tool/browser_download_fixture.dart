import 'dart:io';

Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8787);
  stdout.writeln('Browser download fixture: http://127.0.0.1:${server.port}/');
  await for (final request in server) {
    switch (request.uri.path) {
      case '/':
        request.response.headers.contentType = ContentType.html;
        request.response
            .write('''<!doctype html><title>WMAPP download fixture</title>
<ul>
<li><a href="/files/direct.pdf">Direct file URL</a></li>
<li><a href="/attachment">Content-Disposition attachment</a></li>
<li><a href="/files/from-attribute.txt" download="chosen.txt">HTML download attribute</a></li>
<li><a href="/files/duplicate.txt" download>Duplicate filename (click twice)</a></li>
<li><a href="/failed">Failed response</a></li>
</ul>''');
      case '/files/direct.pdf':
        request.response.headers.contentType =
            ContentType('application', 'pdf');
        request.response.write('%PDF-1.4\nWMAPP fixture\n');
      case '/attachment':
        request.response.headers.set(
            'content-disposition', 'attachment; filename="server-report.txt"');
        request.response.write('header attachment fixture\n');
      case '/files/from-attribute.txt':
        request.response.write('download attribute fixture\n');
      case '/files/duplicate.txt':
        request.response.write('collision fixture\n');
      case '/failed':
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write('intentional failure\n');
      default:
        request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  }
}
