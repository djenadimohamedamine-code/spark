import 'dart:io';

void main() async {
  var url1 = 'https://mt1.google.com/vt/lyrs=m,traffic&x=137&y=100&z=8';
  var url2 = 'https://mt0.google.com/vt/lyrs=m@221097413,traffic,transit,bike&hl=fr&x=137&y=100&z=8';
  
  var req1 = await HttpClient().getUrl(Uri.parse(url1));
  var res1 = await req1.close();
  print('URL1 status: ${res1.statusCode} content: ${res1.headers.contentType}');
  
  var req2 = await HttpClient().getUrl(Uri.parse(url2));
  var res2 = await req2.close();
  print('URL2 status: ${res2.statusCode} content: ${res2.headers.contentType}');
}
