var preview_timer;

function onTextChange()
{
	if (preview_timer) window.clearInterval(preview_timer);
	preview_timer = window.setInterval(updatePreview, 1000);
}

function updatePreview()
{
	var message = $("#message");
	var preview = $("#message-preview");
	$.post("/markup", {message: message.val()}, function(data){
		preview.html(data);
		prettyPrint();
		preview.show();
	});
}
