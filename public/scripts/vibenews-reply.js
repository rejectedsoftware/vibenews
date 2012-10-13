function previewToggle()
{
	var enabled = $("#preview-checkbox").is(':checked');
	if( enabled ){
		var message = $("#message");
		var preview = $("#message-preview");
		preview.height(message.height());
		message.hide();
		preview.show();

		$.post("/markup", {message: message.val()}, function(data){ preview.html(data); });
	} else {
		$("#message").show();
		$("#message-preview").hide();
	}
}
