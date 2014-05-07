var preview_timer;

function onTextChange()
{
	if (preview_timer) window.clearInterval(preview_timer);
	preview_timer = window.setInterval(updatePreview, 1000);
	adjustSizes();
	return true;
}

function updatePreview()
{
	window.clearInterval(preview_timer);
	preview_timer = null;
	var message = $("#message");
	var preview = $("#message-preview");
	$.post("/markup", {message: message.val()}, function(data){
		preview.html(data);
		prettyPrint();
		adjustSizes();
		preview.show();
	});
	return false;
}

function adjustSizes()
{
	var message = $("#message");
	var preview = $("#message-preview");
	console.log($("#message-area").css("display"));
	if ($("#message-area").css("display") == "flex")
		message.height(preview.height());
}